-- =====================================================================
-- Triggers Transaccionales de Inventario, Pesos, Cadena de Frío y Auditoría
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Nota técnica para defensa:
--   En los nodos standby (réplica física por streaming WAL) estos triggers
--   NO se vuelven a disparar: los efectos exactos sobre contenedor,
--   detalle_mercancia y bitacora_auditoria llegan ya aplicados en el flujo WAL.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

-- Detectar automáticamente el número de nodo si no se pasó con -v nodo=N
\if :{?nodo}
\else
  SELECT COALESCE((SELECT MIN(id_terminal_maritima)::INT FROM puerto.manifiesto_carga), 1) AS nodo \gset
\endif
SELECT :nodo::BIGINT * 1000000000 AS base,
       :nodo::BIGINT * 1000000000 + 999999999 AS tope \gset

---------------------------------------------------------------------
-- 1. TRIGGER DE VALIDACIÓN DE PESOS Y CADENA DE FRÍO EN detalle_mercancia
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
    SELECT id_contenedor, numero_iso, tara_kg, peso_max_kg,
           requiere_refrigeracion, id_estado_contenedor
      INTO v_cont
      FROM puerto.contenedor
     WHERE id_contenedor = NEW.id_contenedor
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El contenedor % referenciado en detalle_mercancia no existe.', NEW.id_contenedor
            USING ERRCODE = '23503';
    END IF;

    -- Impedir agregar o alterar carga física de un contenedor ya DESPACHADO (7)
    IF v_cont.id_estado_contenedor = 7 AND (
        TG_OP = 'INSERT'
        OR NEW.peso_kg <> OLD.peso_kg
        OR NEW.cantidad <> OLD.cantidad
        OR NEW.id_partida_arancelaria <> OLD.id_partida_arancelaria
    ) THEN
        RAISE EXCEPTION 'Operación denegada: no se puede agregar ni modificar mercancía física en el contenedor % porque ya fue DESPACHADO.',
            v_cont.numero_iso
            USING ERRCODE = 'P0006';
    END IF;

    -- Validar regla de negocio de cadena de frío (partidas 1 y 2 son refrigeradas)
    IF v_cont.requiere_refrigeracion AND NEW.id_partida_arancelaria NOT IN (1, 2) THEN
        RAISE EXCEPTION 'Violación de cadena de frío: el contenedor % es refrigerado y exige mercancía refrigerada (partidas 1 o 2, recibida: %).',
            v_cont.numero_iso, NEW.id_partida_arancelaria
            USING ERRCODE = '23514';
    ELSIF NOT v_cont.requiere_refrigeracion AND NEW.id_partida_arancelaria IN (1, 2) THEN
        RAISE EXCEPTION 'Violación de cadena de frío: la partida refrigerada % exige un contenedor con refrigeración activa (contenedor seco: %).',
            NEW.id_partida_arancelaria, v_cont.numero_iso
            USING ERRCODE = '23514';
    END IF;

    -- Validar que tara_kg + suma(peso_kg) <= peso_max_kg
    SELECT COALESCE(SUM(peso_kg), 0)
      INTO v_peso_previo
      FROM puerto.detalle_mercancia
     WHERE id_contenedor = NEW.id_contenedor
       AND (TG_OP = 'INSERT' OR id_detalle_mercancia <> OLD.id_detalle_mercancia);

    v_peso_final := v_cont.tara_kg + v_peso_previo + NEW.peso_kg;

    IF v_peso_final > v_cont.peso_max_kg THEN
        RAISE EXCEPTION 'Violación de peso máximo en contenedor %: tara (% kg) + mercancía previa (% kg) + línea actual (% kg) = % kg excede el máximo (% kg).',
            v_cont.numero_iso, v_cont.tara_kg, v_peso_previo, NEW.peso_kg, v_peso_final, v_cont.peso_max_kg
            USING ERRCODE = '23514';
    END IF;

    -- Mantener coherencia automática entre estado del contenedor e inventario al insertar
    IF TG_OP = 'INSERT' THEN
        NEW.estado_inventario := CASE v_cont.id_estado_contenedor
            WHEN 5 THEN 'BLOQUEADO'
            WHEN 7 THEN 'DESPACHADO'
            ELSE 'DISPONIBLE'
        END;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_detalle_mercancia ON puerto.detalle_mercancia;
CREATE TRIGGER trg_validar_detalle_mercancia
BEFORE INSERT OR UPDATE OF id_contenedor, id_partida_arancelaria, cantidad, peso_kg
ON puerto.detalle_mercancia
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_detalle_mercancia();

---------------------------------------------------------------------
-- 2. TRIGGER DE PROTECCIÓN DE ESTADO Y PESO EN contenedor
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION puerto.fn_validar_contenedor()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_peso_mercancia NUMERIC(12,2);
BEGIN
    -- Impedir revertir un contenedor que ya salió despachado de la terminal
    IF OLD.id_estado_contenedor = 7 AND NEW.id_estado_contenedor <> 7 THEN
        RAISE EXCEPTION 'Transición inválida: el contenedor % ya fue DESPACHADO y no puede cambiar al estado %.',
            OLD.numero_iso, NEW.id_estado_contenedor
            USING ERRCODE = 'P0006';
    END IF;

    -- Impedir pasar directo de RETENIDO (5) a DESPACHADO (7) sin inspección de LIBERACION
    IF OLD.id_estado_contenedor = 5 AND NEW.id_estado_contenedor = 7 THEN
        RAISE EXCEPTION 'Transición prohibida: el contenedor % está RETENIDO y no puede pasar directamente a DESPACHADO sin liberación previa.',
            OLD.numero_iso
            USING ERRCODE = 'P0005';
    END IF;

    -- Si se modifica tara_kg o peso_max_kg, verificar que la carga existente siga cabiendo
    IF NEW.tara_kg <> OLD.tara_kg OR NEW.peso_max_kg <> OLD.peso_max_kg THEN
        SELECT COALESCE(SUM(peso_kg), 0)
          INTO v_peso_mercancia
          FROM puerto.detalle_mercancia
         WHERE id_contenedor = NEW.id_contenedor;

        IF (NEW.tara_kg + v_peso_mercancia) > NEW.peso_max_kg THEN
            RAISE EXCEPTION 'Ajuste de pesos inválido en contenedor %: tara (% kg) + mercancía actual (% kg) supera peso_max_kg (% kg).',
                NEW.numero_iso, NEW.tara_kg, v_peso_mercancia, NEW.peso_max_kg
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validar_contenedor ON puerto.contenedor;
CREATE TRIGGER trg_validar_contenedor
BEFORE UPDATE OF id_estado_contenedor, tara_kg, peso_max_kg
ON puerto.contenedor
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_contenedor();

---------------------------------------------------------------------
-- 3. TRIGGERS DE BLOQUEO / LIBERACIÓN / DESPACHO EN inspeccion_transito
--    Tipo 3 (RETENCION)  -> contenedor=5 (RETENIDO),  inventario='BLOQUEADO'
--    Tipo 4 (LIBERACION) -> contenedor=6 (LIBERADO),  inventario='DISPONIBLE'
--    Tipo 5 (DESPACHO)   -> contenedor=7 (DESPACHADO),inventario='DESPACHADO'
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION puerto.fn_validar_inspeccion_transito()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cont              RECORD;
    v_lineas_bloqueadas INT;
BEGIN
    SELECT id_contenedor, numero_iso, id_estado_contenedor
      INTO v_cont
      FROM puerto.contenedor
     WHERE id_contenedor = NEW.id_contenedor
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El contenedor % no existe.', NEW.id_contenedor
            USING ERRCODE = '23503';
    END IF;

    -- Ninguna nueva inspección de control procede sobre un contenedor ya despachado fuera de puerto
    IF v_cont.id_estado_contenedor = 7 THEN
        RAISE EXCEPTION 'Operación rechazada: el contenedor % ya se encuentra DESPACHADO fuera de la terminal.',
            v_cont.numero_iso
            USING ERRCODE = 'P0006';
    END IF;

    IF NEW.id_tipo_inspeccion = 3 THEN
        -- RETENCION aduanera: forzar resultado coherente 'RETENIDO'
        NEW.resultado := 'RETENIDO';

    ELSIF NEW.id_tipo_inspeccion = 4 THEN
        -- LIBERACION aduanera: exige que el contenedor esté actualmente RETENIDO (5)
        IF v_cont.id_estado_contenedor <> 5 THEN
            RAISE EXCEPTION 'Operación rechazada: solo se puede registrar LIBERACION para un contenedor RETENIDO (contenedor % está en estado %).',
                v_cont.numero_iso, v_cont.id_estado_contenedor
                USING ERRCODE = 'P0008';
        END IF;
        NEW.resultado := 'AUTORIZADO';

    ELSIF NEW.id_tipo_inspeccion = 5 THEN
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
          FROM puerto.detalle_mercancia
         WHERE id_contenedor = NEW.id_contenedor
           AND estado_inventario = 'BLOQUEADO';

        IF v_lineas_bloqueadas > 0 THEN
            RAISE EXCEPTION 'Despacho prohibido: el contenedor % mantiene % línea(s) de inventario BLOQUEADO.',
                v_cont.numero_iso, v_lineas_bloqueadas
                USING ERRCODE = 'P0005';
        END IF;

        NEW.resultado := 'AUTORIZADO';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION puerto.fn_aplicar_efecto_inspeccion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.id_tipo_inspeccion = 3 THEN
        -- RETENCION: bloquear contenedor e inventario aduanero
        UPDATE puerto.contenedor
           SET id_estado_contenedor = 5
         WHERE id_contenedor = NEW.id_contenedor;

        UPDATE puerto.detalle_mercancia
           SET estado_inventario = 'BLOQUEADO'
         WHERE id_contenedor = NEW.id_contenedor;

    ELSIF NEW.id_tipo_inspeccion = 4 THEN
        -- LIBERACION: liberar contenedor e inventario aduanero
        UPDATE puerto.contenedor
           SET id_estado_contenedor = 6
         WHERE id_contenedor = NEW.id_contenedor;

        UPDATE puerto.detalle_mercancia
           SET estado_inventario = 'DISPONIBLE'
         WHERE id_contenedor = NEW.id_contenedor;

    ELSIF NEW.id_tipo_inspeccion = 5 THEN
        -- DESPACHO: marcar contenedor e inventario como despachados
        UPDATE puerto.contenedor
           SET id_estado_contenedor = 7
         WHERE id_contenedor = NEW.id_contenedor;

        UPDATE puerto.detalle_mercancia
           SET estado_inventario = 'DESPACHADO'
         WHERE id_contenedor = NEW.id_contenedor;

    ELSIF NEW.id_tipo_inspeccion = 2 THEN
        -- REVISION_FISICA: si estaba en buque/descargado/patio, pasa a EN_INSPECCION (4) con inventario DISPONIBLE
        UPDATE puerto.contenedor
           SET id_estado_contenedor = 4
         WHERE id_contenedor = NEW.id_contenedor
           AND id_estado_contenedor IN (1, 2, 3);
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_01_validar_inspeccion ON puerto.inspeccion_transito;
CREATE TRIGGER trg_01_validar_inspeccion
BEFORE INSERT ON puerto.inspeccion_transito
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_validar_inspeccion_transito();

DROP TRIGGER IF EXISTS trg_02_aplicar_efecto_inspeccion ON puerto.inspeccion_transito;
CREATE TRIGGER trg_02_aplicar_efecto_inspeccion
AFTER INSERT ON puerto.inspeccion_transito
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_aplicar_efecto_inspeccion();

---------------------------------------------------------------------
-- 4. BITÁCORA DE AUDITORÍA TRANSACCIONAL (EXTRA DE SEGURIDAD)
---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS puerto.bitacora_auditoria (
    id_evento       BIGINT GENERATED BY DEFAULT AS IDENTITY
                    (START WITH :base MINVALUE :base MAXVALUE :tope) PRIMARY KEY,
    fecha_hora      TIMESTAMPTZ NOT NULL DEFAULT now(),
    usuario_sesion  TEXT NOT NULL DEFAULT session_user,
    rol_activo      TEXT NOT NULL DEFAULT current_user,
    ip_cliente      INET DEFAULT inet_client_addr(),
    tabla_afectada  VARCHAR(40) NOT NULL,
    operacion       VARCHAR(15) NOT NULL,
    id_registro     BIGINT NOT NULL,
    detalle         JSONB
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
    IF TG_TABLE_NAME = 'manifiesto_carga' THEN
        v_id_reg := COALESCE(NEW.id_manifiesto_carga, OLD.id_manifiesto_carga);
        v_detalle := jsonb_build_object(
            'numero_manifiesto', COALESCE(NEW.numero_manifiesto, OLD.numero_manifiesto),
            'estado_anterior', CASE WHEN TG_OP <> 'INSERT' THEN OLD.estado END,
            'estado_nuevo',    CASE WHEN TG_OP <> 'DELETE' THEN NEW.estado END
        );
    ELSIF TG_TABLE_NAME = 'contenedor' THEN
        v_id_reg := COALESCE(NEW.id_contenedor, OLD.id_contenedor);
        v_detalle := jsonb_build_object(
            'numero_iso', COALESCE(NEW.numero_iso, OLD.numero_iso),
            'estado_anterior', CASE WHEN TG_OP <> 'INSERT' THEN OLD.id_estado_contenedor END,
            'estado_nuevo',    CASE WHEN TG_OP <> 'DELETE' THEN NEW.id_estado_contenedor END
        );
    END IF;

    INSERT INTO puerto.bitacora_auditoria (
        tabla_afectada, operacion, id_registro, detalle
    ) VALUES (
        TG_TABLE_NAME, TG_OP, v_id_reg, v_detalle
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION puerto.fn_registrar_auditoria() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_auditoria_manifiesto ON puerto.manifiesto_carga;
CREATE TRIGGER trg_auditoria_manifiesto
AFTER INSERT OR UPDATE OF estado OR DELETE ON puerto.manifiesto_carga
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_registrar_auditoria();

DROP TRIGGER IF EXISTS trg_auditoria_contenedor ON puerto.contenedor;
CREATE TRIGGER trg_auditoria_contenedor
AFTER INSERT OR UPDATE OF id_estado_contenedor OR DELETE ON puerto.contenedor
FOR EACH ROW
EXECUTE FUNCTION puerto.fn_registrar_auditoria();

