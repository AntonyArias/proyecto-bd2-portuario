-- =====================================================================
-- PRUEBA ACID 2: CONSISTENCIA (Preservación de invariantes y restricciones)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Duración estimada: ~5 segundos
-- Cómo correr desde la raíz del repo:
--   docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
--     psql -U operador_user -d puerto -f - < pruebas/acid/02_consistencia.sql
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

\echo '====================================================================='
\echo ' PRUEBA 2 - CONSISTENCIA (Restricciones CHECK, FK, Triggers y Reglas)'
\echo '====================================================================='

SELECT numero_imo AS imo_test FROM puerto.buque ORDER BY id_buque LIMIT 1 \gset
SELECT id_contenedor AS id_cont_retenido, numero_iso AS iso_retenido
  FROM puerto.contenedor
 WHERE id_estado_contenedor = 5
 ORDER BY id_contenedor
 LIMIT 1 \gset

\set ON_ERROR_STOP off

\echo ''
\echo '--- Caso 2A: Violacion de fragmentacion horizontal (insertar terminal 2 Limon en nodo 1 Moin) ---'
CALL puerto.sp_ingresar_manifiesto(
    2::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T2-ILEGAL01', 'Miami', now(),
    '[{"id_tipo_contenedor":1,"numero_iso":"LIMU7700010","tara_kg":2200,"peso_max_kg":30480,"requiere_refrigeracion":false,
       "detalles":[{"id_partida_arancelaria":6,"descripcion":"Carga otra terminal","cantidad":10,"peso_kg":500,"valor_declarado":5000}]}]'::JSONB,
    NULL
);

\echo ''
\echo '--- Caso 2B: Violacion de formato ISO 6346 del contenedor (CHECK regex ^[A-Z]{4}[0-9]{7}$) ---'
CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T1-ISO-MALO', 'Miami', now(),
    '[{"id_tipo_contenedor":1,"numero_iso":"9999INVALID","tara_kg":2200,"peso_max_kg":30480,"requiere_refrigeracion":false,
       "detalles":[{"id_partida_arancelaria":6,"descripcion":"ISO invalido","cantidad":10,"peso_kg":500,"valor_declarado":5000}]}]'::JSONB,
    NULL
);

\echo ''
\echo '--- Caso 2C: Violacion de regla de cadena de frio (mercancia seca en contenedor refrigerado 20RF) ---'
CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T1-FRIO-MAL', 'Colon', now(),
    '[{"id_tipo_contenedor":4,"numero_iso":"MOIU7700099","tara_kg":2300,"peso_max_kg":30480,"requiere_refrigeracion":true,"temperatura_c":2.0,
       "detalles":[{"id_partida_arancelaria":6,"descripcion":"Laptops en contenedor RF","cantidad":15,"peso_kg":600,"valor_declarado":12000}]}]'::JSONB,
    NULL
);

\echo ''
\echo '--- Caso 2D: Intento de despachar un contenedor RETENIDO por aduana (estado 5 / BLOQUEADO) ---'
\echo 'Contenedor retenido de prueba:' :id_cont_retenido '(' :iso_retenido ')'
CALL puerto.sp_despachar_mercancia(
    :id_cont_retenido,
    'AA-00001',
    'Intento prohibido de despachar contenedor retenido',
    NULL
);

\set ON_ERROR_STOP on

\echo ''
\echo '--- Verificacion final de invariantes de Consistencia en el nodo (todas deben ser 0 = OK) ---'
SELECT prueba,
       violaciones,
       CASE WHEN violaciones = 0 THEN 'OK - CONSISTENTE' ELSE 'FALLA' END AS estado
FROM (
  SELECT 'manifiestos_de_otra_terminal' AS prueba, count(*) AS violaciones
    FROM puerto.manifiesto_carga WHERE id_terminal_maritima <> 1
  UNION ALL
  SELECT 'contenedores_sin_manifiesto', count(*)
    FROM puerto.contenedor c LEFT JOIN puerto.manifiesto_carga m USING (id_manifiesto_carga)
   WHERE m.id_manifiesto_carga IS NULL
  UNION ALL
  SELECT 'contenedores_sin_detalle', count(*)
    FROM puerto.contenedor c
   WHERE NOT EXISTS (SELECT 1 FROM puerto.detalle_mercancia d WHERE d.id_contenedor = c.id_contenedor)
  UNION ALL
  SELECT 'sobrepeso_tara_mas_carga', count(*)
    FROM puerto.contenedor c
    JOIN (SELECT id_contenedor, sum(peso_kg) AS p FROM puerto.detalle_mercancia GROUP BY 1) d USING (id_contenedor)
   WHERE c.tara_kg + d.p > c.peso_max_kg
  UNION ALL
  SELECT 'inventario_vs_estado_contenedor', count(*)
    FROM puerto.detalle_mercancia d JOIN puerto.contenedor c USING (id_contenedor)
   WHERE (c.id_estado_contenedor = 5 AND d.estado_inventario <> 'BLOQUEADO')
      OR (c.id_estado_contenedor = 7 AND d.estado_inventario <> 'DESPACHADO')
      OR (c.id_estado_contenedor NOT IN (5,7) AND d.estado_inventario <> 'DISPONIBLE')
) q
ORDER BY prueba;

