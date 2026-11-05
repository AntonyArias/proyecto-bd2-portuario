-- =====================================================================
-- Procedimiento Almacenado: puerto.sp_ingresar_manifiesto
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Descripción:
--   Registra en UNA SOLA TRANSACCIÓN ATÓMICA un manifiesto de carga junto
--   con todos sus contenedores, líneas de detalle de mercancía (cifrando
--   valores declarados y arancelarios con pgcrypto) y su inspección inicial
--   de ingreso. Si cualquier contenedor o detalle falla una regla de negocio
--   o restricción de integridad, toda la operación hace ROLLBACK completo.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

-- Eliminar firma previa de 7 parámetros si existía en versiones anteriores
DROP PROCEDURE IF EXISTS puerto.sp_ingresar_manifiesto(
    SMALLINT, CHAR(7), VARCHAR(12), VARCHAR(20), VARCHAR(60), TIMESTAMPTZ, BIGINT
);

CREATE OR REPLACE PROCEDURE puerto.sp_ingresar_manifiesto(
    p_id_terminal            SMALLINT,
    p_numero_imo             CHAR(7),
    p_licencia_agente        VARCHAR(12),
    p_numero_manifiesto      VARCHAR(20),
    p_puerto_origen          VARCHAR(60),
    p_fecha_arribo           TIMESTAMPTZ,
    p_contenedores           JSONB,
    INOUT p_id_manifiesto_generado BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_buque           INT;
    v_id_agente          INT;
    v_terminal_valida    SMALLINT;
    v_cont               JSONB;
    v_det                JSONB;
    v_idx_cont           INT := 0;
    v_idx_det            INT := 0;
    v_id_tipo_cont       SMALLINT;
    v_codigo_tipo_cont   VARCHAR(5);
    v_es_tipo_rf         BOOLEAN;
    v_req_refrig         BOOLEAN;
    v_temp_c             NUMERIC(4,1);
    v_id_estado_inicial  SMALLINT;
    v_id_contenedor      BIGINT;
    v_id_partida         SMALLINT;
    v_tasa_arancel       NUMERIC(5,2);
    v_valor_declarado    NUMERIC(14,2);
    v_valor_arancelario  NUMERIC(14,2);
BEGIN
    -- 1. Validar que la terminal marítima exista
    SELECT id_terminal_maritima INTO v_terminal_valida
      FROM puerto.terminal_maritima
     WHERE id_terminal_maritima = p_id_terminal;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La terminal marítima con ID % no está registrada en el sistema.', p_id_terminal
            USING ERRCODE = 'P0001';
    END IF;

    -- 2. Validar existencia del Buque por su número IMO
    SELECT id_buque INTO v_id_buque
      FROM puerto.buque
     WHERE numero_imo = p_numero_imo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El buque con número IMO % no se encuentra registrado.', p_numero_imo
            USING ERRCODE = 'P0002';
    END IF;

    -- 3. Validar Agente Aduanero autorizado y activo
    SELECT id_agente_aduanero INTO v_id_agente
      FROM puerto.agente_aduanero
     WHERE codigo_licencia = p_licencia_agente
       AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El agente aduanero con licencia % no existe o se encuentra inactivo.', p_licencia_agente
            USING ERRCODE = 'P0003';
    END IF;

    -- 4. Validar que el manifiesto incluya al menos un contenedor en formato JSONB array
    IF p_contenedores IS NULL
       OR jsonb_typeof(p_contenedores) <> 'array'
       OR jsonb_array_length(p_contenedores) = 0 THEN
        RAISE EXCEPTION 'El manifiesto % debe contener al menos un contenedor en p_contenedores (JSONB array).',
            p_numero_manifiesto
            USING ERRCODE = 'P0009';
    END IF;

    -- 5. Insertar cabecera del Manifiesto de Carga
    --    (El CHECK id_terminal_maritima = :nodo garantiza que solo entre en el fragmento correcto)
    INSERT INTO puerto.manifiesto_carga (
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

    -- 6. Recorrer e insertar cada Contenedor y sus Detalles de Mercancía
    FOR v_cont IN SELECT value FROM jsonb_array_elements(p_contenedores)
    LOOP
        v_idx_cont := v_idx_cont + 1;

        -- Cada contenedor exige al menos una línea en detalle_mercancia (invariante 3FN / verificación)
        IF v_cont->'detalles' IS NULL
           OR jsonb_typeof(v_cont->'detalles') <> 'array'
           OR jsonb_array_length(v_cont->'detalles') = 0 THEN
            RAISE EXCEPTION 'El contenedor #% (%) del manifiesto % no incluye líneas de detalle_mercancia.',
                v_idx_cont, COALESCE(v_cont->>'numero_iso', 'SIN_ISO'), p_numero_manifiesto
                USING ERRCODE = 'P0009';
        END IF;

        v_id_tipo_cont := (v_cont->>'id_tipo_contenedor')::SMALLINT;
        SELECT codigo INTO v_codigo_tipo_cont
          FROM puerto.tipo_contenedor
         WHERE id_tipo_contenedor = v_id_tipo_cont;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Tipo de contenedor inválido (%) en contenedor #% (%).',
                v_id_tipo_cont, v_idx_cont, COALESCE(v_cont->>'numero_iso', 'SIN_ISO')
                USING ERRCODE = 'P0009';
        END IF;

        v_es_tipo_rf := (v_codigo_tipo_cont LIKE '%RF');
        v_req_refrig := COALESCE((v_cont->>'requiere_refrigeracion')::BOOLEAN, v_es_tipo_rf);
        v_temp_c     := (v_cont->>'temperatura_c')::NUMERIC(4,1);

        IF v_es_tipo_rf <> v_req_refrig THEN
            RAISE EXCEPTION 'Inconsistencia en contenedor %: el tipo % (%) no coincide con requiere_refrigeracion=%',
                COALESCE(v_cont->>'numero_iso', 'SIN_ISO'), v_codigo_tipo_cont,
                CASE WHEN v_es_tipo_rf THEN 'refrigerado' ELSE 'seco' END, v_req_refrig
                USING ERRCODE = '23514';
        END IF;

        -- Estado inicial permitido al registrar manifiesto: 1 (EN_BUQUE), 2 (DESCARGADO) o 3 (EN_PATIO)
        v_id_estado_inicial := COALESCE((v_cont->>'id_estado_contenedor')::SMALLINT, 2);
        IF v_id_estado_inicial NOT IN (1, 2, 3) THEN
            RAISE EXCEPTION 'Estado inicial inválido (%) para contenedor nuevo %; debe ser 1 (EN_BUQUE), 2 (DESCARGADO) o 3 (EN_PATIO).',
                v_id_estado_inicial, COALESCE(v_cont->>'numero_iso', 'SIN_ISO')
                USING ERRCODE = '23514';
        END IF;

        INSERT INTO puerto.contenedor (
            id_manifiesto_carga,
            id_tipo_contenedor,
            id_estado_contenedor,
            numero_iso,
            tara_kg,
            peso_max_kg,
            requiere_refrigeracion,
            temperatura_c
        ) VALUES (
            p_id_manifiesto_generado,
            v_id_tipo_cont,
            v_id_estado_inicial,
            v_cont->>'numero_iso',
            (v_cont->>'tara_kg')::NUMERIC(10,2),
            (v_cont->>'peso_max_kg')::NUMERIC(10,2),
            v_req_refrig,
            v_temp_c
        )
        RETURNING id_contenedor INTO v_id_contenedor;

        -- Insertar las líneas de detalle de mercancía del contenedor (el trigger valida pesos y cadena de frío)
        v_idx_det := 0;
        FOR v_det IN SELECT value FROM jsonb_array_elements(v_cont->'detalles')
        LOOP
            v_idx_det := v_idx_det + 1;
            v_id_partida := (v_det->>'id_partida_arancelaria')::SMALLINT;

            SELECT tasa_arancel_pct INTO v_tasa_arancel
              FROM puerto.partida_arancelaria
             WHERE id_partida_arancelaria = v_id_partida;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Partida arancelaria inválida (%) en detalle #% del contenedor %.',
                    v_id_partida, v_idx_det, v_cont->>'numero_iso'
                    USING ERRCODE = 'P0009';
            END IF;

            v_valor_declarado := (v_det->>'valor_declarado')::NUMERIC(14,2);
            IF v_valor_declarado IS NULL OR v_valor_declarado < 0 THEN
                RAISE EXCEPTION 'El valor_declarado debe ser >= 0 en detalle #% del contenedor %.',
                    v_idx_det, v_cont->>'numero_iso'
                    USING ERRCODE = '23514';
            END IF;

            v_valor_arancelario := COALESCE(
                (v_det->>'valor_arancelario')::NUMERIC(14,2),
                ROUND(v_valor_declarado * v_tasa_arancel / 100.0, 2)
            );

            INSERT INTO puerto.detalle_mercancia (
                id_contenedor,
                id_partida_arancelaria,
                descripcion,
                cantidad,
                peso_kg,
                valor_declarado_enc,
                valor_arancelario_enc,
                estado_inventario
            ) VALUES (
                v_id_contenedor,
                v_id_partida,
                v_det->>'descripcion',
                (v_det->>'cantidad')::INT,
                (v_det->>'peso_kg')::NUMERIC(10,2),
                puerto.cifrar(v_valor_declarado::TEXT),
                puerto.cifrar(v_valor_arancelario::TEXT),
                'DISPONIBLE'
            );
        END LOOP;

        -- Registrar inspección inicial de INGRESO en la bitácora transaccional
        INSERT INTO puerto.inspeccion_transito (
            id_contenedor,
            id_tipo_inspeccion,
            id_agente_aduanero,
            resultado,
            observaciones
        ) VALUES (
            v_id_contenedor,
            1, -- INGRESO
            v_id_agente,
            'CONFORME',
            'Ingreso inicial registrado con manifiesto ' || p_numero_manifiesto
        );
    END LOOP;

    RAISE NOTICE 'Manifiesto % (ID %) ingresado exitosamente con % contenedor(es) en terminal %.',
        p_numero_manifiesto, p_id_manifiesto_generado, v_idx_cont, p_id_terminal;

EXCEPTION
    WHEN OTHERS THEN
        p_id_manifiesto_generado := NULL;
        RAISE EXCEPTION 'Error al ingresar manifiesto [SQLSTATE %]: %. Transacción revertida por atomicidad (ROLLBACK).',
            SQLSTATE, SQLERRM
            USING ERRCODE = SQLSTATE;
END;
$$;
