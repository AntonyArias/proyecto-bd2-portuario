-- 03_verificacion.sql | Evidencia para la rubrica. Correr en cada nodo:
--   psql -U postgres -d puerto -p 5441 -v nodo=1 -f 03_verificacion.sql
-- Las pruebas de la seccion 2 deben dar 0 (resultado OK).
SET search_path = puerto, public;

\echo == 1. Conteos del nodo ==
SELECT 'manifiesto_carga' AS tabla, count(*) AS filas FROM manifiesto_carga UNION ALL
SELECT 'contenedor', count(*) FROM contenedor UNION ALL
SELECT 'detalle_mercancia', count(*) FROM detalle_mercancia UNION ALL
SELECT 'inspeccion_transito', count(*) FROM inspeccion_transito;

\echo == 2. Pruebas (violaciones deben ser 0) ==
SELECT prueba, violaciones, CASE WHEN violaciones = 0 THEN 'OK' ELSE 'FALLA' END AS resultado
FROM (
  SELECT 'manifiestos_de_otra_terminal' AS prueba, count(*) AS violaciones
    FROM manifiesto_carga WHERE id_terminal_maritima <> :nodo
  UNION ALL
  SELECT 'contenedores_sin_manifiesto', count(*) FROM contenedor c
    LEFT JOIN manifiesto_carga m USING (id_manifiesto_carga) WHERE m.id_manifiesto_carga IS NULL
  UNION ALL
  SELECT 'contenedores_sin_detalle', count(*) FROM contenedor c
    WHERE NOT EXISTS (SELECT 1 FROM detalle_mercancia d WHERE d.id_contenedor = c.id_contenedor)
  UNION ALL
  SELECT 'sobrepeso', count(*) FROM contenedor c
    JOIN (SELECT id_contenedor, sum(peso_kg) AS p FROM detalle_mercancia GROUP BY 1) d USING (id_contenedor)
    WHERE c.tara_kg + d.p > c.peso_max_kg
  UNION ALL
  SELECT 'inventario_vs_estado_contenedor', count(*) FROM detalle_mercancia d
    JOIN contenedor c USING (id_contenedor)
    WHERE (c.id_estado_contenedor = 5 AND d.estado_inventario <> 'BLOQUEADO')
       OR (c.id_estado_contenedor = 7 AND d.estado_inventario <> 'DESPACHADO')
       OR (c.id_estado_contenedor NOT IN (5,7) AND d.estado_inventario <> 'DISPONIBLE')
  UNION ALL
  SELECT 'cifrado_no_descifra', count(*) FROM agente_aduanero
    WHERE puerto.descifrar(cedula_enc) IS NULL
) q
ORDER BY prueba;

\echo == 3. Cifrado ida y vuelta ==
SELECT id_agente_aduanero, puerto.descifrar(cedula_enc) AS cedula
FROM agente_aduanero ORDER BY 1 LIMIT 3;
