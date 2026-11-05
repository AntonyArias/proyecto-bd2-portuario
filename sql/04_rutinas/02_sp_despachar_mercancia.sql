-- =====================================================================
-- Procedimiento Almacenado: puerto.sp_despachar_mercancia
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Descripción:
--   Ejecuta el despacho aduanero de un contenedor aplicando control de
--   concurrencia pesimista (SELECT ... FOR UPDATE), validando estado del
--   contenedor, integridad del inventario y pesos, registrando el evento
--   en inspeccion_transito y actualizando el estado del manifiesto.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE OR REPLACE PROCEDURE puerto.sp_despachar_mercancia(
    p_id_contenedor           BIGINT,
    p_licencia_agente         VARCHAR(12),
    p_observaciones           TEXT DEFAULT 'Despacho aduanero autorizado',
    INOUT p_id_inspeccion_generada BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_agente          INT;
    v_cont               RECORD;
    v_total_lineas       INT;
    v_lineas_bloqueadas  INT;
    v_lineas_despachadas INT;
    v_peso_mercancia     NUMERIC(12,2);
    v_pendientes_manif   INT;
BEGIN
    -- 1. Validar Agente Aduanero autorizado y activo
    SELECT id_agente_aduanero INTO v_id_agente
      FROM puerto.agente_aduanero
     WHERE codigo_licencia = p_licencia_agente
       AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El agente aduanero con licencia % no existe o se encuentra inactivo.', p_licencia_agente
            USING ERRCODE = 'P0003';
    END IF;

    -- 2. Bloquear exclusivamente la fila del contenedor (FOR UPDATE sin JOIN
    --    para que EvalPlanQual en READ COMMITTED releea el nuevo id_estado_contenedor tras el bloqueo)
    SELECT c.id_contenedor,
           c.numero_iso,
           c.id_manifiesto_carga,
           c.id_estado_contenedor,
           c.tara_kg,
           c.peso_max_kg
      INTO v_cont
      FROM puerto.contenedor c
     WHERE c.id_contenedor = p_id_contenedor
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El contenedor con ID % no existe en la terminal de este nodo.', p_id_contenedor
            USING ERRCODE = 'P0004';
    END IF;

    -- 3. Validar reglas de negocio sobre el estado del contenedor
    IF v_cont.id_estado_contenedor = 5 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % (%) se encuentra RETENIDO por control aduanero.',
            v_cont.numero_iso, p_id_contenedor
            USING ERRCODE = 'P0005';
    END IF;

    IF v_cont.id_estado_contenedor = 7 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % (%) ya fue DESPACHADO previamente.',
            v_cont.numero_iso, p_id_contenedor
            USING ERRCODE = 'P0006';
    END IF;

    IF v_cont.id_estado_contenedor = 1 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % (%) aún figura EN_BUQUE y no ha sido descargado.',
            v_cont.numero_iso, p_id_contenedor
            USING ERRCODE = 'P0007';
    END IF;

    -- 4. Bloquear las filas hijas de detalle_mercancia y verificar consistencia de inventario y peso
    PERFORM 1
       FROM puerto.detalle_mercancia
      WHERE id_contenedor = p_id_contenedor
        FOR UPDATE;

    SELECT COUNT(*),
           COUNT(*) FILTER (WHERE estado_inventario = 'BLOQUEADO'),
           COUNT(*) FILTER (WHERE estado_inventario = 'DESPACHADO'),
           COALESCE(SUM(peso_kg), 0)
      INTO v_total_lineas, v_lineas_bloqueadas, v_lineas_despachadas, v_peso_mercancia
      FROM puerto.detalle_mercancia
     WHERE id_contenedor = p_id_contenedor;

    IF v_total_lineas = 0 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % (%) no posee detalle de mercancía registrado.',
            v_cont.numero_iso, p_id_contenedor
            USING ERRCODE = 'P0009';
    END IF;

    IF v_lineas_bloqueadas > 0 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % posee % línea(s) de inventario BLOQUEADO.',
            v_cont.numero_iso, v_lineas_bloqueadas
            USING ERRCODE = 'P0005';
    END IF;

    IF v_lineas_despachadas > 0 THEN
        RAISE EXCEPTION 'Despacho denegado: el contenedor % ya posee líneas marcadas como DESPACHADO.',
            v_cont.numero_iso
            USING ERRCODE = 'P0006';
    END IF;

    IF (v_cont.tara_kg + v_peso_mercancia) > v_cont.peso_max_kg THEN
        RAISE EXCEPTION 'Despacho denegado por sobrepeso en contenedor %: tara (% kg) + mercancía (% kg) > máximo (% kg).',
            v_cont.numero_iso, v_cont.tara_kg, v_peso_mercancia, v_cont.peso_max_kg
            USING ERRCODE = '23514';
    END IF;

    -- 5. Registrar el despacho en inspeccion_transito
    --    (El trigger AFTER INSERT sobre inspeccion_transito actualiza automáticamente
    --     contenedor -> 7 DESPACHADO y detalle_mercancia -> DESPACHADO)
    INSERT INTO puerto.inspeccion_transito (
        id_contenedor,
        id_tipo_inspeccion,
        id_agente_aduanero,
        resultado,
        observaciones
    ) VALUES (
        p_id_contenedor,
        5, -- DESPACHO
        v_id_agente,
        'AUTORIZADO',
        COALESCE(NULLIF(BTRIM(p_observaciones), ''), 'Despacho aduanero autorizado')
    )
    RETURNING id_inspeccion_transito INTO p_id_inspeccion_generada;

    -- Asegurar transición de estado incluso si el procedimiento se invocara sin el trigger activo
    UPDATE puerto.contenedor
       SET id_estado_contenedor = 7
     WHERE id_contenedor = p_id_contenedor
       AND id_estado_contenedor <> 7;

    UPDATE puerto.detalle_mercancia
       SET estado_inventario = 'DESPACHADO'
     WHERE id_contenedor = p_id_contenedor
       AND estado_inventario <> 'DESPACHADO';

    -- 6. Actualizar el estado del manifiesto padre (DESPACHO_PARCIAL o CERRADO)
    PERFORM 1
       FROM puerto.manifiesto_carga
      WHERE id_manifiesto_carga = v_cont.id_manifiesto_carga
        FOR UPDATE;

    SELECT COUNT(*)
      INTO v_pendientes_manif
      FROM puerto.contenedor
     WHERE id_manifiesto_carga = v_cont.id_manifiesto_carga
       AND id_estado_contenedor <> 7;

    UPDATE puerto.manifiesto_carga
       SET estado = CASE WHEN v_pendientes_manif = 0 THEN 'CERRADO' ELSE 'DESPACHO_PARCIAL' END
     WHERE id_manifiesto_carga = v_cont.id_manifiesto_carga;

    RAISE NOTICE 'Contenedor % (ID %) despachado exitosamente. Inspección generada: %.',
        v_cont.numero_iso, p_id_contenedor, p_id_inspeccion_generada;

EXCEPTION
    WHEN OTHERS THEN
        p_id_inspeccion_generada := NULL;
        RAISE EXCEPTION 'Error al despachar mercancía [SQLSTATE %]: %',
            SQLSTATE, SQLERRM
            USING ERRCODE = SQLSTATE;
END;
$$;

