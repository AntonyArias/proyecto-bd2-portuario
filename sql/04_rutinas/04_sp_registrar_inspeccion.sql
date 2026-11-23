-- =====================================================================
-- Procedimiento Almacenado: puerto.sp_registrar_inspeccion
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad (integración con Rol 1)
-- Descripción:
--   Interfaz transaccional pensada para el generador de carga concurrente
--   del Rol 1 (pruebas/generador_carga.py --modo llamada). Valida que el
--   contenedor pertenezca al fragmento (terminal), valida agente activo,
--   aplica bloqueo de fila FOR UPDATE e inserta en InspeccionTransito,
--   disparando automáticamente los triggers de retención/liberación/despacho.
-- Ejemplo de llamada desde generador_carga.py:
--   python pruebas/generador_carga.py --modo llamada \
--     --llamada "CALL puerto.sp_registrar_inspeccion(%(id_terminal)s::smallint, %(id_contenedor)s, %(id_tipo_inspeccion)s::smallint, %(id_agente_aduanero)s, %(resultado)s, %(observaciones)s)"
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE OR REPLACE PROCEDURE puerto.sp_registrar_inspeccion(
    p_id_terminal        SMALLINT,
    p_id_contenedor      BIGINT,
    p_id_tipo_inspeccion SMALLINT,
    p_id_agente_aduanero INT,
    p_resultado          VARCHAR(12),
    p_observaciones      TEXT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_terminal_real SMALLINT;
    v_activo        BOOLEAN;
BEGIN
    -- 1. Validar que el agente exista y esté activo
    IF p_id_agente_aduanero IS NOT NULL THEN
        SELECT "CB_Activo" INTO v_activo
          FROM puerto."AgenteAduanero"
         WHERE "CI_IdAgenteAduanero" = p_id_agente_aduanero;

        IF NOT FOUND OR NOT v_activo THEN
            RAISE EXCEPTION 'El agente aduanero ID % no existe o se encuentra inactivo.', p_id_agente_aduanero
                USING ERRCODE = 'P0003';
        END IF;
    END IF;

    -- 2. Bloquear fila del contenedor y confirmar localidad del fragmento
    SELECT m."CI_IdTerminalMaritima"
      INTO v_terminal_real
      FROM puerto."Contenedor" c
      JOIN puerto."ManifiestoCarga" m
        ON m."CI_IdManifiestoCarga" = c."CI_IdManifiestoCarga"
     WHERE c."CI_IdContenedor" = p_id_contenedor
       FOR UPDATE OF c;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Contenedor % no encontrado en este nodo.', p_id_contenedor
            USING ERRCODE = 'P0004';
    END IF;

    IF v_terminal_real <> p_id_terminal THEN
        RAISE EXCEPTION 'Violación de fragmentación: el contenedor % pertenece a la terminal %, no a la terminal %.',
            p_id_contenedor, v_terminal_real, p_id_terminal
            USING ERRCODE = '23514';
    END IF;

    -- 3. Insertar en InspeccionTransito (los triggers validan estado y actualizan inventario)
    INSERT INTO puerto."InspeccionTransito" (
        "CI_IdContenedor",
        "CI_IdTipoInspeccion",
        "CI_IdAgenteAduanero",
        "CT_Resultado",
        "CT_Observaciones"
    ) VALUES (
        p_id_contenedor,
        p_id_tipo_inspeccion,
        p_id_agente_aduanero,
        p_resultado,
        p_observaciones
    );
END;
$$;
