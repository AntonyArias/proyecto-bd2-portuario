-- =====================================================================
-- PRUEBA ACID 4: DURABILIDAD - PASO 1 (Transacción confirmada con COMMIT)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Registra y confirma (COMMIT) un nuevo manifiesto completo justo antes
-- de provocar un apagado eléctrico forzoso (SIGKILL) del contenedor primario.
-- =====================================================================

\pset pager off
\set ON_ERROR_STOP on
SET search_path = puerto, public;

SELECT numero_imo AS imo_test FROM puerto.buque ORDER BY id_buque LIMIT 1 \gset
SELECT 'MAN-T1-D' || to_char(clock_timestamp(), 'HH24MISSMS') AS num_man_dur,
       'DURU' || lpad(((extract(epoch FROM clock_timestamp())::BIGINT * 1000) % 10000000)::TEXT, 7, '0') AS iso_dur \gset

SELECT jsonb_build_array(
  jsonb_build_object(
    'id_tipo_contenedor', 2,
    'numero_iso', :'iso_dur',
    'tara_kg', 3850.00,
    'peso_max_kg', 32500.00,
    'requiere_refrigeracion', false,
    'detalles', jsonb_build_array(
      jsonb_build_object(
        'id_partida_arancelaria', 10,
        'descripcion', 'Medicamentos criticos prueba de durabilidad WAL',
        'cantidad', 250,
        'peso_kg', 3200.00,
        'valor_declarado', 85000.00
      )
    )
  )
)::TEXT AS payload_dur \gset

\echo '====================================================================='
\echo ' [DURABILIDAD - PASO 1] Ejecutando transaccion y confirmando COMMIT'
\echo ' Manifiesto:' :'num_man_dur' '| Contenedor:' :'iso_dur'
\echo '====================================================================='

BEGIN;
CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT,
    :'imo_test',
    'AA-00001',
    :'num_man_dur',
    'Hamburgo',
    now(),
    (:'payload_dur')::JSONB,
    NULL
);
COMMIT;

SELECT id_manifiesto_carga,
       numero_manifiesto,
       fecha_registro,
       pg_current_wal_lsn() AS wal_lsn_confirmado_en_disco
  FROM puerto.manifiesto_carga
 WHERE numero_manifiesto = :'num_man_dur';

