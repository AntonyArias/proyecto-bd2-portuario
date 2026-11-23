-- =====================================================================
-- Triggers Transaccionales de Inventario, Pesos, Cadena de Frío y Auditoría
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- Nota técnica para defensa:
--   En los nodos standby (réplica física por streaming WAL) estos triggers
--   NO se vuelven a disparar: los efectos exactos sobre Contenedor,
--   DetalleMercancia y BitacoraAuditoria llegan ya aplicados en el flujo WAL.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

\if :{?nodo}
\else
  SELECT COALESCE((SELECT MIN("CI_IdTerminalMaritima")::INT FROM puerto."ManifiestoCarga"), 1) AS nodo \gset
\endif
SELECT :nodo::BIGINT * 1000000000 AS base,
       :nodo::BIGINT * 1000000000 + 999999999 AS tope \gset

---------------------------------------------------------------------
-- 1. TRIGGER DE VALIDACIÓN DE PESOS Y CADENA DE FRÍO EN DetalleMercancia
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION puerto.fn_validar_detalle_mercancia()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cont        RECORD;
    v_peso_previo NUMERIC(12,2);
    v_peso_final  NUMERIC(12,2);
BEGIN
    -- Bloquear el contenedor padre para evitar anomalía de write-skew en inserciones concurrentes
    SELECT "CI_IdContenedor"          AS id_contenedor,
           "CT_NumeroIso"             AS numero_iso,
           "CD_TaraKg"                AS tara_kg,
           "CD_PesoMaxKg"             AS peso_max_kg,
           "CB_RequiereRefrigeracion" AS requiere_refrigeracion,
           "CI_IdEstadoContenedor"    AS id_estado_contenedor
      INTO v_cont
      FROM puerto."Contenedor"
     WHERE "CI_IdContenedor" = NEW."CI_IdContenedor"
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El contenedor % referenciado en DetalleMercancia no existe.', NEW."CI_IdContenedor"
            USING ERRCODE = '23503';
    END IF;

    -- Impedir agregar o alterar carga física de un contenedor ya DESPACHADO (7)
    IF v_cont.id_estado_contenedor = 7 AND (
        TG_OP = 'INSERT'
        OR NEW."CD_PesoKg" <> OLD."CD_PesoKg"
        OR NEW."CI_Cantidad" <> OLD."CI_Cantidad"
        OR NEW."CI_IdPartidaArancelaria" <> OLD."CI_IdPartidaArancelaria"
    ) THEN
        RAISE EXCEPTION 'Operación denegada: no se puede agregar ni modificar mercancía física en el contenedor % porque ya fue DESPACHADO.',
            v_cont.numero_iso
            USING ERRCODE = 'P0006';
    END IF;

    -- Validar regla de negocio de cadena de frío (partidas 1 y 2 son refrigeradas)
    IF v_cont.requiere_refrigeracion AND NEW."CI_IdPartidaArancelaria" NOT IN (1, 2) THEN
        RAISE EXCEPTION 'Violación de cadena de frío: el contenedor % es refrigerado y exige mercancía refrigerada (partidas 1 o 2, recibida: %).',
            v_cont.numero_iso, NEW."CI_IdPartidaArancelaria"
            USING ERRCODE = '23514';
    ELSIF NOT v_cont.requiere_refrigeracion AND NEW."CI_IdPartidaArancelaria" IN (1, 2) THEN
        RAISE EXCEPTION 'Violación de cadena de frío: la partida refrigerada % exige un contenedor con refrigeración activa (contenedor seco: %).',
            NEW."CI_IdPartidaArancelaria", v_cont.numero_iso
            USING ERRCODE = '23514';
    END IF;

    -- Validar que CD_TaraKg + SUM(CD_PesoKg) <= CD_PesoMaxKg
    SELECT COALESCE(SUM("CD_PesoKg"), 0)
      INTO v_peso_previo
      FROM puerto."DetalleMercancia"
     WHERE "CI_IdContenedor" = NEW."CI_IdContenedor"
       AND (TG_OP = 'INSERT' OR "CI_IdDetalleMercancia" <> OLD."CI_IdDetalleMercancia");

    v_peso_final := v_cont.tara_kg + v_peso_previo + NEW."CD_PesoKg";

    IF v_peso_final > v_cont.peso_max_kg THEN
        RAISE EXCEPTION 'Violación de peso máximo en contenedor %: tara (% kg) + mercancía previa (% kg) + línea actual (% kg) = % kg excede el máximo (% kg).',
            v_cont.numero_iso, v_cont.tara_kg, v_peso_previo, NEW."CD_PesoKg", v_peso_final, v_cont.peso_max_kg
            USING ERRCODE = '23514';
    END IF;

    -- Mantener coherencia automática entre estado del contenedor e inventario al insertar
    IF TG_OP = 'INSERT' THEN
        NEW."CT_EstadoInventario" := CASE v_cont.id_estado_contenedor
            WHEN 5 THEN 'BLOQUEADO'
            WHEN 7 THEN 'DESPACHADO'
            ELSE 'DISPONIBLE'
        END;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_detalle_mercancia ON puerto."DetalleMercancia";
CREATE TRIGGER trg_validar_detalle_mercancia
BEFORE INSERT OR UPDATE OF "CI_IdContenedor", "CI_IdPartidaArancelaria", "CI_Cantidad", "CD_PesoKg"
ON puerto."DetalleMercancia"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_detalle_mercancia();

---------------------------------------------------------------------
-- 2. TRIGGER DE PROTECCIÓN DE ESTADO Y PESO EN Contenedor
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION puerto.fn_validar_contenedor()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_peso_mercancia NUMERIC(12,2);
BEGIN
    -- Impedir revertir un contenedor que ya salió despachado de la terminal
    IF OLD."CI_IdEstadoContenedor" = 7 AND NEW."CI_IdEstadoContenedor" <> 7 THEN
        RAISE EXCEPTION 'Transición inválida: el contenedor % ya fue DESPACHADO y no puede cambiar al estado %.',
            OLD."CT_NumeroIso", NEW."CI_IdEstadoContenedor"
            USING ERRCODE = 'P0006';
    END IF;

    -- Impedir pasar directo de RETENIDO (5) a DESPACHADO (7) sin inspección de LIBERACION
    IF OLD."CI_IdEstadoContenedor" = 5 AND NEW."CI_IdEstadoContenedor" = 7 THEN
        RAISE EXCEPTION 'Transición prohibida: el contenedor % está RETENIDO y no puede pasar directamente a DESPACHADO sin liberación previa.',
            OLD."CT_NumeroIso"
            USING ERRCODE = 'P0005';
    END IF;

    -- Si se modifica tara o peso máximo, verificar que la carga existente siga cabiendo
    IF NEW."CD_TaraKg" <> OLD."CD_TaraKg" OR NEW."CD_PesoMaxKg" <> OLD."CD_PesoMaxKg" THEN
        SELECT COALESCE(SUM("CD_PesoKg"), 0)
          INTO v_peso_mercancia
          FROM puerto."DetalleMercancia"
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

        IF (NEW."CD_TaraKg" + v_peso_mercancia) > NEW."CD_PesoMaxKg" THEN
            RAISE EXCEPTION 'Ajuste de pesos inválido en contenedor %: tara (% kg) + mercancía actual (% kg) supera CD_PesoMaxKg (% kg).',
                NEW."CT_NumeroIso", NEW."CD_TaraKg", v_peso_mercancia, NEW."CD_PesoMaxKg"
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_contenedor ON puerto."Contenedor";
CREATE TRIGGER trg_validar_contenedor
BEFORE UPDATE OF "CI_IdEstadoContenedor", "CD_TaraKg", "CD_PesoMaxKg"
ON puerto."Contenedor"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_contenedor();

---------------------------------------------------------------------
-- 3. TRIGGERS DE BLOQUEO / LIBERACIÓN / DESPACHO EN InspeccionTransito
--    Tipo 3 (RETENCION)  -> Contenedor=5 (RETENIDO),   Inventario='BLOQUEADO'
--    Tipo 4 (LIBERACION) -> Contenedor=6 (LIBERADO),   Inventario='DISPONIBLE'
--    Tipo 5 (DESPACHO)   -> Contenedor=7 (DESPACHADO), Inventario='DESPACHADO'
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION puerto.fn_validar_inspeccion_transito()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cont              RECORD;
    v_lineas_bloqueadas INT;
BEGIN
    SELECT "CI_IdContenedor"       AS id_contenedor,
           "CT_NumeroIso"          AS numero_iso,
           "CI_IdEstadoContenedor" AS id_estado_contenedor
      INTO v_cont
      FROM puerto."Contenedor"
     WHERE "CI_IdContenedor" = NEW."CI_IdContenedor"
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El contenedor % no existe.', NEW."CI_IdContenedor"
            USING ERRCODE = '23503';
    END IF;

    -- Ninguna nueva inspección de control procede sobre un contenedor ya despachado fuera de puerto
    IF v_cont.id_estado_contenedor = 7 THEN
        RAISE EXCEPTION 'Operación rechazada: el contenedor % ya se encuentra DESPACHADO fuera de la terminal.',
            v_cont.numero_iso
            USING ERRCODE = 'P0006';
    END IF;

    IF NEW."CI_IdTipoInspeccion" = 3 THEN
        -- RETENCION aduanera: forzar resultado coherente 'RETENIDO'
        NEW."CT_Resultado" := 'RETENIDO';

    ELSIF NEW."CI_IdTipoInspeccion" = 4 THEN
        -- LIBERACION aduanera: exige que el contenedor esté actualmente RETENIDO (5)
        IF v_cont.id_estado_contenedor <> 5 THEN
            RAISE EXCEPTION 'Operación rechazada: solo se puede registrar LIBERACION para un contenedor RETENIDO (contenedor % está en estado %).',
                v_cont.numero_iso, v_cont.id_estado_contenedor
                USING ERRCODE = 'P0008';
        END IF;
        NEW."CT_Resultado" := 'AUTORIZADO';

    ELSIF NEW."CI_IdTipoInspeccion" = 5 THEN
        -- DESPACHO aduanero: prohibido si está RETENIDO (5), EN_BUQUE (1) o con inventario bloqueado
        IF v_cont.id_estado_contenedor = 5 THEN
            RAISE EXCEPTION 'Despacho prohibido: el contenedor % se encuentra RETENIDO.',
                v_cont.numero_iso
                USING ERRCODE = 'P0005';
        END IF;

        IF v_cont.id_estado_contenedor = 1 THEN
            RAISE EXCEPTION 'Despacho prohibido: el contenedor % sigue EN_BUQUE.',
                v_cont.numero_iso
                USING ERRCODE = 'P0007';
        END IF;

        SELECT COUNT(*) INTO v_lineas_bloqueadas
          FROM puerto."DetalleMercancia"
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor"
           AND "CT_EstadoInventario" = 'BLOQUEADO';

        IF v_lineas_bloqueadas > 0 THEN
            RAISE EXCEPTION 'Despacho prohibido: el contenedor % mantiene % línea(s) de inventario BLOQUEADO.',
                v_cont.numero_iso, v_lineas_bloqueadas
                USING ERRCODE = 'P0005';
        END IF;

        NEW."CT_Resultado" := 'AUTORIZADO';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION puerto.fn_aplicar_efecto_inspeccion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW."CI_IdTipoInspeccion" = 3 THEN
        -- RETENCION: bloquear contenedor e inventario aduanero
        UPDATE puerto."Contenedor"
           SET "CI_IdEstadoContenedor" = 5
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

        UPDATE puerto."DetalleMercancia"
           SET "CT_EstadoInventario" = 'BLOQUEADO'
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

    ELSIF NEW."CI_IdTipoInspeccion" = 4 THEN
        -- LIBERACION: liberar contenedor e inventario aduanero
        UPDATE puerto."Contenedor"
           SET "CI_IdEstadoContenedor" = 6
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

        UPDATE puerto."DetalleMercancia"
           SET "CT_EstadoInventario" = 'DISPONIBLE'
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

    ELSIF NEW."CI_IdTipoInspeccion" = 5 THEN
        -- DESPACHO: marcar contenedor e inventario como despachados
        UPDATE puerto."Contenedor"
           SET "CI_IdEstadoContenedor" = 7
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

        UPDATE puerto."DetalleMercancia"
           SET "CT_EstadoInventario" = 'DESPACHADO'
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor";

    ELSIF NEW."CI_IdTipoInspeccion" = 2 THEN
        -- REVISION_FISICA: si estaba en buque/descargado/patio, pasa a EN_INSPECCION (4)
        UPDATE puerto."Contenedor"
           SET "CI_IdEstadoContenedor" = 4
         WHERE "CI_IdContenedor" = NEW."CI_IdContenedor"
           AND "CI_IdEstadoContenedor" IN (1, 2, 3);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_01_validar_inspeccion ON puerto."InspeccionTransito";
CREATE TRIGGER trg_01_validar_inspeccion
BEFORE INSERT ON puerto."InspeccionTransito"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_inspeccion_transito();

DROP TRIGGER IF EXISTS trg_02_aplicar_efecto_inspeccion ON puerto."InspeccionTransito";
CREATE TRIGGER trg_02_aplicar_efecto_inspeccion
AFTER INSERT ON puerto."InspeccionTransito"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_aplicar_efecto_inspeccion();

---------------------------------------------------------------------
-- 4. BITÁCORA DE AUDITORÍA TRANSACCIONAL (EXTRA DE SEGURIDAD)
---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS puerto."BitacoraAuditoria" (
    "CI_IdEvento"      BIGINT GENERATED BY DEFAULT AS IDENTITY
                       (START WITH :base MINVALUE :base MAXVALUE :tope) NOT NULL,
    "CF_FechaHora"     TIMESTAMPTZ NOT NULL DEFAULT now(),
    "CT_UsuarioSesion" TEXT NOT NULL DEFAULT session_user,
    "CT_RolActivo"     TEXT NOT NULL DEFAULT current_user,
    "CT_IpCliente"     INET DEFAULT inet_client_addr(),
    "CT_TablaAfectada" VARCHAR(40) NOT NULL,
    "CT_Operacion"     VARCHAR(15) NOT NULL,
    "CI_IdRegistro"    BIGINT NOT NULL,
    "CT_Detalle"       JSONB,
    CONSTRAINT "PK_BitacoraAuditoria" PRIMARY KEY ("CI_IdEvento")
);

CREATE OR REPLACE FUNCTION puerto.fn_registrar_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = puerto, pg_temp
AS $$
DECLARE
    v_id_reg  BIGINT;
    v_detalle JSONB;
BEGIN
    IF TG_TABLE_NAME = 'ManifiestoCarga' THEN
        v_id_reg := COALESCE(NEW."CI_IdManifiestoCarga", OLD."CI_IdManifiestoCarga");
        v_detalle := jsonb_build_object(
            'numero_manifiesto', COALESCE(NEW."CT_NumeroManifiesto", OLD."CT_NumeroManifiesto"),
            'estado_anterior', CASE WHEN TG_OP <> 'INSERT' THEN OLD."CT_Estado" END,
            'estado_nuevo',    CASE WHEN TG_OP <> 'DELETE' THEN NEW."CT_Estado" END
        );
    ELSIF TG_TABLE_NAME = 'Contenedor' THEN
        v_id_reg := COALESCE(NEW."CI_IdContenedor", OLD."CI_IdContenedor");
        v_detalle := jsonb_build_object(
            'numero_iso', COALESCE(NEW."CT_NumeroIso", OLD."CT_NumeroIso"),
            'estado_anterior', CASE WHEN TG_OP <> 'INSERT' THEN OLD."CI_IdEstadoContenedor" END,
            'estado_nuevo',    CASE WHEN TG_OP <> 'DELETE' THEN NEW."CI_IdEstadoContenedor" END
        );
    END IF;

    INSERT INTO puerto."BitacoraAuditoria" (
        "CT_TablaAfectada", "CT_Operacion", "CI_IdRegistro", "CT_Detalle"
    ) VALUES (
        TG_TABLE_NAME, TG_OP, v_id_reg, v_detalle
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION puerto.fn_registrar_auditoria() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_auditoria_manifiesto ON puerto."ManifiestoCarga";
CREATE TRIGGER trg_auditoria_manifiesto
AFTER INSERT OR UPDATE OF "CT_Estado" OR DELETE ON puerto."ManifiestoCarga"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_registrar_auditoria();

DROP TRIGGER IF EXISTS trg_auditoria_contenedor ON puerto."Contenedor";
CREATE TRIGGER trg_auditoria_contenedor
AFTER INSERT OR UPDATE OF "CI_IdEstadoContenedor" OR DELETE ON puerto."Contenedor"
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_registrar_auditoria();
