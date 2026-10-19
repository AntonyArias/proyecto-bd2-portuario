-- =====================================================================
-- Procedimiento Almacenado: sp_ingresar_manifiesto
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Descripción: Inserta un manifiesto de carga validando la existencia
--              del buque y el agente aduanero, garantizando atomicidad (ACID).
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE OR REPLACE PROCEDURE puerto.sp_ingresar_manifiesto(
    p_id_terminal    SMALLINT,
    p_numero_imo     CHAR(7),
    p_licencia_agente VARCHAR(12),
    p_numero_manifiesto VARCHAR(20),
    p_puerto_origen  VARCHAR(60),
    p_fecha_arribo   TIMESTAMPTZ,
    OUT p_id_manifiesto_generado BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_buque INT;
    v_id_agente INT;
    v_terminal_valida SMALLINT;
BEGIN
    -- 1. Validar que la terminal exista
    SELECT id_terminal_maritima INTO v_terminal_valida
    FROM terminal_maritima
    WHERE id_terminal_maritima = p_id_terminal;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La terminal marítima con ID % no está registrada en el sistema.', p_id_terminal
        USING ERRCODE = 'P0001';
    END IF;

    -- 2. Obtener y validar el Buque por su número IMO
    SELECT id_buque INTO v_id_buque
    FROM buque
    WHERE numero_imo = p_numero_imo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El buque con número IMO % no se encuentra registrado.', p_numero_imo
        USING ERRCODE = 'P0002';
    END IF;

    -- 3. Obtener y validar el Agente Aduanero por su licencia y que esté activo
    SELECT id_agente_aduanero INTO v_id_agente
    FROM agente_aduanero
    WHERE codigo_licencia = p_licencia_agente AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El agente aduanero con licencia % no existe o se encuentra inactivo.', p_licencia_agente
        USING ERRCODE = 'P0003';
    END IF;

    -- 4. Inserción atómica del Manifiesto de Carga
    -- (El disparador de secuencia del nodo asignará automáticamente el ID dentro de su rango disjunto)
    INSERT INTO manifiesto_carga (
        id_terminal_maritima,
        id_buque,
        id_agente_aduanero,
        numero_manifiesto,
        puerto_origen,
        fecha_arribo,
        estado
    ) VALUES (
        p_id_terminal,
        v_id_buque,
        v_id_agente,
        p_numero_manifiesto,
        p_puerto_origen,
        p_fecha_arribo,
        'REGISTRADO'
    )
    RETURNING id_manifiesto_carga INTO p_id_manifiesto_generado;

    -- Notificación de éxito en la consola del backend
    RAISE NOTICE 'Manifiesto % registrado exitosamente con ID % en la terminal %.', 
        p_numero_manifiesto, p_id_manifiesto_generado, p_id_terminal;

EXCEPTION
    WHEN OTHERS THEN
        -- Captura cualquier error imprevisto o violación de restricción y aborta limpiamente
        RAISE EXCEPTION 'Error al ingresar manifiesto: %. Transacción revertida (ROLLBACK).', SQLERRM;
END;
$$;
