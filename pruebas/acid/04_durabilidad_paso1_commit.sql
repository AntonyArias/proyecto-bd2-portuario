-- =====================================================================
-- PRUEBA ACID 4: DURABILIDAD - PASO 1 (Transacción confirmada con COMMIT)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
\set ON_ERROR_STOP on
SET search_path = puerto, public;

SELECT "CT_NumeroImo" AS imo_test FROM puerto."Buque" ORDER BY "CI_IdBuque" LIMIT 1 \gset
SELECT 'MAN-T1-' || lpad((900000 + (((extract(epoch FROM clock_timestamp())::BIGINT * 10) + (extract(microseconds FROM clock_timestamp())::INT / 100000)) % 99999))::TEXT, 6, '0') AS num_man_dur,
       'DURU' || lpad(((extract(epoch FROM clock_timestamp())::BIGINT * 1000) % 10000000)::TEXT, 7, '0') AS iso_dur \gset

SELECT jsonb_build_array(
  jsonb_build_object(
    'CI_IdTipoContenedor', 2,
    'CT_NumeroIso', :'iso_dur',
    'CD_TaraKg', 3850.00,
    'CD_PesoMaxKg', 32500.00,
    'CB_RequiereRefrigeracion', false,
    'detalles', jsonb_build_array(
      jsonb_build_object(
        'CI_IdPartidaArancelaria', 10,
        'CT_Descripcion', 'Medicamentos criticos prueba de durabilidad WAL',
        'CI_Cantidad', 250,
        'CD_PesoKg', 3200.00,
        'CD_ValorDeclarado', 85000.00
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

SELECT "CI_IdManifiestoCarga",
       "CT_NumeroManifiesto",
       "CF_FechaRegistro",
       pg_current_wal_lsn() AS wal_lsn_confirmado_en_disco
  FROM puerto."ManifiestoCarga"
 WHERE "CT_NumeroManifiesto" = :'num_man_dur';
