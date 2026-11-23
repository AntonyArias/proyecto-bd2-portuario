-- =====================================================================
-- PRUEBA ACID 2: CONSISTENCIA (Preservación de invariantes y restricciones)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

\echo '====================================================================='
\echo ' PRUEBA 2 - CONSISTENCIA (Restricciones CHECK, FK, Triggers y Reglas)'
\echo '====================================================================='

SELECT "CT_NumeroImo" AS imo_test FROM puerto."Buque" ORDER BY "CI_IdBuque" LIMIT 1 \gset
SELECT "CI_IdContenedor" AS id_cont_retenido, "CT_NumeroIso" AS iso_retenido
  FROM puerto."Contenedor"
 WHERE "CI_IdEstadoContenedor" = 5
 ORDER BY "CI_IdContenedor"
 LIMIT 1 \gset

\set ON_ERROR_STOP off

\echo ''
\echo '--- Caso 2A: Violacion de fragmentacion horizontal (insertar terminal 2 Limon en nodo 1 Moin) ---'
CALL puerto.sp_ingresar_manifiesto(
    2::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T2-ILEGAL01', 'Miami', now(),
    '[{"CI_IdTipoContenedor":1,"CT_NumeroIso":"LIMU7700010","CD_TaraKg":2200,"CD_PesoMaxKg":30480,"CB_RequiereRefrigeracion":false,
       "detalles":[{"CI_IdPartidaArancelaria":6,"CT_Descripcion":"Carga otra terminal","CI_Cantidad":10,"CD_PesoKg":500,"CD_ValorDeclarado":5000}]}]'::JSONB,
    NULL
);

\echo ''
\echo '--- Caso 2B: Violacion de formato ISO 6346 del contenedor (CHECK regex ^[A-Z]{4}[0-9]{7}$) ---'
CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T1-ISO-MALO', 'Miami', now(),
    '[{"CI_IdTipoContenedor":1,"CT_NumeroIso":"9999INVALID","CD_TaraKg":2200,"CD_PesoMaxKg":30480,"CB_RequiereRefrigeracion":false,
       "detalles":[{"CI_IdPartidaArancelaria":6,"CT_Descripcion":"ISO invalido","CI_Cantidad":10,"CD_PesoKg":500,"CD_ValorDeclarado":5000}]}]'::JSONB,
    NULL
);

\echo ''
\echo '--- Caso 2C: Violacion de regla de cadena de frio (mercancia seca en contenedor refrigerado 20RF) ---'
CALL puerto.sp_ingresar_manifiesto(
    1::SMALLINT, :'imo_test', 'AA-00001', 'MAN-T1-FRIO-MAL', 'Colon', now(),
    '[{"CI_IdTipoContenedor":4,"CT_NumeroIso":"MOIU7700099","CD_TaraKg":2300,"CD_PesoMaxKg":30480,"CB_RequiereRefrigeracion":true,"CD_TemperaturaC":2.0,
       "detalles":[{"CI_IdPartidaArancelaria":6,"CT_Descripcion":"Laptops en contenedor RF","CI_Cantidad":15,"CD_PesoKg":600,"CD_ValorDeclarado":12000}]}]'::JSONB,
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
    FROM puerto."ManifiestoCarga" WHERE "CI_IdTerminalMaritima" <> 1
  UNION ALL
  SELECT 'contenedores_sin_manifiesto', count(*)
    FROM puerto."Contenedor" c LEFT JOIN puerto."ManifiestoCarga" m USING ("CI_IdManifiestoCarga")
   WHERE m."CI_IdManifiestoCarga" IS NULL
  UNION ALL
  SELECT 'contenedores_sin_detalle', count(*)
    FROM puerto."Contenedor" c
   WHERE NOT EXISTS (SELECT 1 FROM puerto."DetalleMercancia" d WHERE d."CI_IdContenedor" = c."CI_IdContenedor")
  UNION ALL
  SELECT 'sobrepeso_tara_mas_carga', count(*)
    FROM puerto."Contenedor" c
    JOIN (SELECT "CI_IdContenedor", sum("CD_PesoKg") AS p FROM puerto."DetalleMercancia" GROUP BY 1) d USING ("CI_IdContenedor")
   WHERE c."CD_TaraKg" + d.p > c."CD_PesoMaxKg"
  UNION ALL
  SELECT 'inventario_vs_estado_contenedor', count(*)
    FROM puerto."DetalleMercancia" d JOIN puerto."Contenedor" c USING ("CI_IdContenedor")
   WHERE (c."CI_IdEstadoContenedor" = 5 AND d."CT_EstadoInventario" <> 'BLOQUEADO')
      OR (c."CI_IdEstadoContenedor" = 7 AND d."CT_EstadoInventario" <> 'DESPACHADO')
      OR (c."CI_IdEstadoContenedor" NOT IN (5,7) AND d."CT_EstadoInventario" <> 'DISPONIBLE')
) q
ORDER BY prueba;
