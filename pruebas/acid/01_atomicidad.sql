-- =====================================================================
-- PRUEBA ACID 1: ATOMICIDAD ("Todo o Nada" ante error a mitad de rutina)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

\echo '====================================================================='
\echo ' PRUEBA 1 - ATOMICIDAD (sp_ingresar_manifiesto con fallo a mitad)'
\echo '====================================================================='

SELECT count(*) AS man_antes  FROM puerto."ManifiestoCarga"    \gset
SELECT count(*) AS cont_antes FROM puerto."Contenedor"          \gset
SELECT count(*) AS det_antes  FROM puerto."DetalleMercancia"    \gset
SELECT count(*) AS insp_antes FROM puerto."InspeccionTransito"  \gset
SELECT "CT_NumeroImo" AS imo_test FROM puerto."Buque" ORDER BY "CI_IdBuque" LIMIT 1 \gset

\echo ''
\echo '1) Conteos ANTES de llamar a sp_ingresar_manifiesto:'
SELECT :man_antes  AS manifiestos_antes,
       :cont_antes AS contenedores_antes,
       :det_antes  AS detalles_antes,
       :insp_antes AS inspecciones_antes;

\echo ''
\echo '2) Ejecutando sp_ingresar_manifiesto con 2 contenedores:'
\echo '   - Contenedor #1 (MOIU7700010): VALIDO (tara 2200 + carga 4000 = 6200 <= 30480 kg)'
\echo '   - Contenedor #2 (MOIU7700021): ERROR A MITAD (tara 2500 + carga 29500 = 32000 > 30480 kg)'
\echo '   -> Se espera ERROR por sobrepeso y ROLLBACK total (incluyendo cabecera y Contenedor #1).'
\echo ''

\set ON_ERROR_STOP off

CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT,
    :'imo_test',
    'AA-00001',
    'MAN-T1-ACID-ATOM',
    'Rotterdam',
    now(),
    '[
      {
        "CI_IdTipoContenedor": 1,
        "CT_NumeroIso": "MOIU7700010",
        "CD_TaraKg": 2200.00,
        "CD_PesoMaxKg": 30480.00,
        "CB_RequiereRefrigeracion": false,
        "detalles": [
          {
            "CI_IdPartidaArancelaria": 6,
            "CT_Descripcion": "Computadoras portatiles (lote valido)",
            "CI_Cantidad": 80,
            "CD_PesoKg": 4000.00,
            "CD_ValorDeclarado": 65000.00
          }
        ]
      },
      {
        "CI_IdTipoContenedor": 1,
        "CT_NumeroIso": "MOIU7700021",
        "CD_TaraKg": 2500.00,
        "CD_PesoMaxKg": 30480.00,
        "CB_RequiereRefrigeracion": false,
        "detalles": [
          {
            "CI_IdPartidaArancelaria": 13,
            "CT_Descripcion": "Bobinas de acero con sobrepeso deliberado",
            "CI_Cantidad": 10,
            "CD_PesoKg": 29500.00,
            "CD_ValorDeclarado": 42000.00
          }
        ]
      }
    ]'::JSONB,
    NULL
);

\set ON_ERROR_STOP on

\echo ''
\echo '3) Verificando que NO quedaron registros parciales ni huerfanos:'
SELECT
    (SELECT count(*) FROM puerto."ManifiestoCarga" WHERE "CT_NumeroManifiesto" = 'MAN-T1-ACID-ATOM') AS manifiestos_parciales,
    (SELECT count(*) FROM puerto."Contenedor"      WHERE "CT_NumeroIso" IN ('MOIU7700010','MOIU7700021')) AS contenedores_huerfanos,
    (count(*) - :man_antes) AS diferencia_manifiestos,
    CASE
        WHEN count(*) = :man_antes
         AND (SELECT count(*) FROM puerto."Contenedor") = :cont_antes
         AND (SELECT count(*) FROM puerto."DetalleMercancia") = :det_antes
         AND (SELECT count(*) FROM puerto."InspeccionTransito") = :insp_antes
        THEN 'OK - ATOMICIDAD DEMOSTRADA (ROLLBACK 100% COMPLETO)'
        ELSE 'FALLO DE ATOMICIDAD'
    END AS resultado_atomicidad
FROM puerto."ManifiestoCarga";
