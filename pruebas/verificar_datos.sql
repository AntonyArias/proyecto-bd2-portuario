-- verificar_datos.sql | Evidencia para la rubrica: volumen, integridad, fragmento, CHECK y cifrado.
-- Uso (por nodo): psql -U postgres -d puerto -p 544N -v nodo=N -f pruebas/verificar_datos.sql
-- Todas las pruebas de la seccion 2 deben dar 0 violaciones (resultado OK).
-- Se espera correrlo justo despues de la carga: tras la prueba de estres, los triggers
-- cambian estados a proposito y 'inventario_vs_estado_contenedor' deja de aplicar.
\set ON_ERROR_STOP on
\if :{?nodo}
\else
  \echo 'ERROR: falta -v nodo=N'
  \quit
\endif
SET search_path = puerto, public;

\echo
\echo == 1. Conteos por tabla (este nodo) ==
SELECT 'Pais' AS tabla, count(*) AS filas FROM "Pais" UNION ALL
SELECT 'TipoContenedor', count(*) FROM "TipoContenedor" UNION ALL
SELECT 'EstadoContenedor', count(*) FROM "EstadoContenedor" UNION ALL
SELECT 'TipoInspeccion', count(*) FROM "TipoInspeccion" UNION ALL
SELECT 'PartidaArancelaria', count(*) FROM "PartidaArancelaria" UNION ALL
SELECT 'TerminalMaritima', count(*) FROM "TerminalMaritima" UNION ALL
SELECT 'DependenciaAduanera', count(*) FROM "DependenciaAduanera" UNION ALL
SELECT 'Naviera', count(*) FROM "Naviera" UNION ALL
SELECT 'Buque', count(*) FROM "Buque" UNION ALL
SELECT 'AgenteAduanero', count(*) FROM "AgenteAduanero" UNION ALL
SELECT 'ManifiestoCarga', count(*) FROM "ManifiestoCarga" UNION ALL
SELECT 'Contenedor', count(*) FROM "Contenedor" UNION ALL
SELECT 'DetalleMercancia', count(*) FROM "DetalleMercancia" UNION ALL
SELECT 'InspeccionTransito', count(*) FROM "InspeccionTransito";

\echo
\echo == 2. Pruebas de integridad (violaciones deben ser 0) ==
SELECT prueba, violaciones, CASE WHEN violaciones = 0 THEN 'OK' ELSE 'FALLA' END AS resultado
FROM (
  -- fragmento: solo la terminal de este nodo
  SELECT 'manifiestos_de_otra_terminal' AS prueba, count(*) AS violaciones
    FROM "ManifiestoCarga" WHERE "CI_IdTerminalMaritima" <> :nodo
  UNION ALL
  SELECT 'numero_manifiesto_formato', count(*) FROM "ManifiestoCarga"
    WHERE "CT_NumeroManifiesto" !~ ('^MAN-T' || :nodo || '-[0-9]{6}$')
  UNION ALL
  -- rango de IDs propio del nodo
  SELECT 'ids_fuera_del_rango_del_nodo', count(*) FROM (
      SELECT "CI_IdManifiestoCarga" AS id FROM "ManifiestoCarga"
      UNION ALL SELECT "CI_IdContenedor" FROM "Contenedor"
      UNION ALL SELECT "CI_IdDetalleMercancia" FROM "DetalleMercancia"
      UNION ALL SELECT "CI_IdInspeccionTransito" FROM "InspeccionTransito") x
    WHERE id NOT BETWEEN :nodo * 1000000000::bigint AND :nodo * 1000000000::bigint + 999999999
  UNION ALL
  -- huerfanos (las FK ya lo impiden; se comprueba como evidencia)
  SELECT 'contenedores_sin_manifiesto', count(*) FROM "Contenedor" c
    LEFT JOIN "ManifiestoCarga" m USING ("CI_IdManifiestoCarga") WHERE m."CI_IdManifiestoCarga" IS NULL
  UNION ALL
  SELECT 'detalles_sin_contenedor', count(*) FROM "DetalleMercancia" d
    LEFT JOIN "Contenedor" c USING ("CI_IdContenedor") WHERE c."CI_IdContenedor" IS NULL
  UNION ALL
  SELECT 'inspecciones_sin_contenedor', count(*) FROM "InspeccionTransito" i
    LEFT JOIN "Contenedor" c USING ("CI_IdContenedor") WHERE c."CI_IdContenedor" IS NULL
  UNION ALL
  SELECT 'contenedores_sin_detalle', count(*) FROM "Contenedor" c
    WHERE NOT EXISTS (SELECT 1 FROM "DetalleMercancia" d WHERE d."CI_IdContenedor" = c."CI_IdContenedor")
  UNION ALL
  -- violaciones de CHECK (comprobadas a mano, deben ser 0)
  SELECT 'tara_no_positiva', count(*) FROM "Contenedor" WHERE "CD_TaraKg" <= 0
  UNION ALL
  SELECT 'tara_mayor_o_igual_peso_max', count(*) FROM "Contenedor" WHERE "CD_TaraKg" >= "CD_PesoMaxKg"
  UNION ALL
  SELECT 'iso_formato_invalido', count(*) FROM "Contenedor" WHERE "CT_NumeroIso" !~ '^[A-Z]{4}[0-9]{7}$'
  UNION ALL
  SELECT 'refrigeracion_incoherente', count(*) FROM "Contenedor"
    WHERE "CB_RequiereRefrigeracion" <> ("CD_TemperaturaC" IS NOT NULL)
  UNION ALL
  -- regla de negocio: tara + peso de la mercancia <= peso maximo
  SELECT 'sobrepeso', count(*) FROM "Contenedor" c
    JOIN (SELECT "CI_IdContenedor", sum("CD_PesoKg") AS p FROM "DetalleMercancia" GROUP BY 1) d
      USING ("CI_IdContenedor")
    WHERE c."CD_TaraKg" + d.p > c."CD_PesoMaxKg"
  UNION ALL
  -- inventario coherente con el estado del contenedor (RETENIDO=5, DESPACHADO=7)
  SELECT 'inventario_vs_estado_contenedor', count(*) FROM "DetalleMercancia" d
    JOIN "Contenedor" c USING ("CI_IdContenedor")
    WHERE (c."CI_IdEstadoContenedor" = 5 AND d."CT_EstadoInventario" <> 'BLOQUEADO')
       OR (c."CI_IdEstadoContenedor" = 7 AND d."CT_EstadoInventario" <> 'DESPACHADO')
       OR (c."CI_IdEstadoContenedor" NOT IN (5,7) AND d."CT_EstadoInventario" <> 'DISPONIBLE')
  UNION ALL
  -- cifrado: todo dato sensible descifra
  SELECT 'cifrado_no_descifra', count(*) FROM (
      SELECT puerto.descifrar("CT_CedulaEnc") AS a, puerto.descifrar("CT_TelefonoEnc") AS b
      FROM "AgenteAduanero") z
    WHERE a IS NULL OR b IS NULL
  UNION ALL
  SELECT 'valores_no_descifran', count(*) FROM (
      SELECT puerto.descifrar("CT_ValorDeclaradoEnc") AS a, puerto.descifrar("CT_ValorArancelarioEnc") AS b
      FROM "DetalleMercancia") z
    WHERE a IS NULL OR b IS NULL
) q
ORDER BY prueba;

\echo
\echo == 3. Metas de volumen (este nodo; metas globales: >20000 filas y >10000 inspecciones) ==
SELECT (SELECT count(*) FROM "ManifiestoCarga") + (SELECT count(*) FROM "Contenedor")
     + (SELECT count(*) FROM "DetalleMercancia") + (SELECT count(*) FROM "InspeccionTransito")
         AS filas_operativas_nodo,
       (SELECT count(*) FROM "InspeccionTransito") AS inspecciones_nodo;

\echo
\echo == 4. Cifrado ida y vuelta (muestra) ==
SELECT "CI_IdAgenteAduanero", puerto.descifrar("CT_CedulaEnc") AS cedula
FROM "AgenteAduanero" ORDER BY 1 LIMIT 3;
