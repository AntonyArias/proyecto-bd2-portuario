-- =====================================================================
-- PRUEBA ACID 1: ATOMICIDAD ("Todo o Nada" ante error a mitad de rutina)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Duración estimada: ~5 segundos
-- Cómo correr desde la raíz del repo:
--   docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
--     psql -U operador_user -d puerto -f - < pruebas/acid/01_atomicidad.sql
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

\echo '====================================================================='
\echo ' PRUEBA 1 - ATOMICIDAD (sp_ingresar_manifiesto con fallo a mitad)'
\echo '====================================================================='

-- Guardar conteos previos para comparar antes vs. después
SELECT count(*) AS man_antes  FROM puerto.manifiesto_carga    \gset
SELECT count(*) AS cont_antes FROM puerto.contenedor          \gset
SELECT count(*) AS det_antes  FROM puerto.detalle_mercancia   \gset
SELECT count(*) AS insp_antes FROM puerto.inspeccion_transito \gset
SELECT numero_imo AS imo_test FROM puerto.buque ORDER BY id_buque LIMIT 1 \gset

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

-- Permitir que psql continúe tras mostrar el error esperado para verificar el estado final
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
        "id_tipo_contenedor": 1,
        "numero_iso": "MOIU7700010",
        "tara_kg": 2200.00,
        "peso_max_kg": 30480.00,
        "requiere_refrigeracion": false,
        "detalles": [
          {
            "id_partida_arancelaria": 6,
            "descripcion": "Computadoras portatiles (lote valido)",
            "cantidad": 80,
            "peso_kg": 4000.00,
            "valor_declarado": 65000.00
          }
        ]
      },
      {
        "id_tipo_contenedor": 1,
        "numero_iso": "MOIU7700021",
        "tara_kg": 2500.00,
        "peso_max_kg": 30480.00,
        "requiere_refrigeracion": false,
        "detalles": [
          {
            "id_partida_arancelaria": 13,
            "descripcion": "Bobinas de acero con sobrepeso deliberado",
            "cantidad": 10,
            "peso_kg": 29500.00,
            "valor_declarado": 42000.00
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
    (SELECT count(*) FROM puerto.manifiesto_carga  WHERE numero_manifiesto = 'MAN-T1-ACID-ATOM') AS manifiestos_parciales,
    (SELECT count(*) FROM puerto.contenedor        WHERE numero_iso IN ('MOIU7700010','MOIU7700021')) AS contenedores_huerfanos,
    (count(*) - :man_antes) AS diferencia_manifiestos,
    CASE
        WHEN count(*) = :man_antes
         AND (SELECT count(*) FROM puerto.contenedor) = :cont_antes
         AND (SELECT count(*) FROM puerto.detalle_mercancia) = :det_antes
         AND (SELECT count(*) FROM puerto.inspeccion_transito) = :insp_antes
        THEN 'OK - ATOMICIDAD DEMOSTRADA (ROLLBACK 100% COMPLETO)'
        ELSE 'FALLO DE ATOMICIDAD'
    END AS resultado_atomicidad
FROM puerto.manifiesto_carga;

