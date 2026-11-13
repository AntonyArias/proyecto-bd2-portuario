-- explain_indices.sql | Justificacion de indices con EXPLAIN (ANALYZE, BUFFERS).
-- Uso: psql -U postgres -d puerto -p 5441 -f pruebas/explain_indices.sql  > docs/explain_resultados.txt
-- Para cada indice: (A) la consulta SIN el indice (se borra dentro de una transaccion y se
-- revierte con ROLLBACK, asi no se pierde) y (B) la misma consulta CON el indice.
-- Comparar 'Execution Time', 'Buffers: shared hit/read' y si el plan usa Index Scan o Seq Scan.
-- Regla: si B no mejora de forma clara frente a A, el indice NO se justifica y se elimina del DDL.
-- NOTA: con tablas pequenas el planner puede preferir Seq Scan aun con indice; repetir con
--       N_MAN mayor (N_MAN=3000 ./sql/cargar.sh 1 --reset) para ver el efecto real.
SET search_path = puerto, public;
\timing off

\echo
\echo ############ 1. IX_Contenedor_CI_IdManifiestoCarga: contenedores de un manifiesto
BEGIN; DROP INDEX "IX_Contenedor_CI_IdManifiestoCarga";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "Contenedor"
 WHERE "CI_IdManifiestoCarga" = (SELECT min("CI_IdManifiestoCarga") + 5 FROM "ManifiestoCarga");
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "Contenedor"
 WHERE "CI_IdManifiestoCarga" = (SELECT min("CI_IdManifiestoCarga") + 5 FROM "ManifiestoCarga");

\echo
\echo ############ 2. IX_DetalleMercancia_CI_IdContenedor: detalle de mercancia de un contenedor
BEGIN; DROP INDEX "IX_DetalleMercancia_CI_IdContenedor";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "DetalleMercancia"
 WHERE "CI_IdContenedor" = (SELECT min("CI_IdContenedor") + 100 FROM "Contenedor");
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "DetalleMercancia"
 WHERE "CI_IdContenedor" = (SELECT min("CI_IdContenedor") + 100 FROM "Contenedor");

\echo
\echo ############ 3. IX_InspeccionTransito_CI_IdContenedor: ultimas inspecciones de un contenedor
BEGIN; DROP INDEX "IX_InspeccionTransito_CI_IdContenedor";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "InspeccionTransito"
 WHERE "CI_IdContenedor" = (SELECT min("CI_IdContenedor") + 100 FROM "Contenedor")
 ORDER BY "CF_FechaHora" DESC LIMIT 5;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "InspeccionTransito"
 WHERE "CI_IdContenedor" = (SELECT min("CI_IdContenedor") + 100 FROM "Contenedor")
 ORDER BY "CF_FechaHora" DESC LIMIT 5;

\echo
\echo ############ 4. IX_Contenedor_CI_IdEstadoContenedor: contenedores retenidos (estado 5)
BEGIN; DROP INDEX "IX_Contenedor_CI_IdEstadoContenedor";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT "CI_IdContenedor", "CT_NumeroIso" FROM "Contenedor" WHERE "CI_IdEstadoContenedor" = 5;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT "CI_IdContenedor", "CT_NumeroIso" FROM "Contenedor" WHERE "CI_IdEstadoContenedor" = 5;

\echo
\echo ############ 5. IX_ManifiestoCarga_CI_IdBuque: manifiestos de un buque
BEGIN; DROP INDEX "IX_ManifiestoCarga_CI_IdBuque";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "ManifiestoCarga" WHERE "CI_IdBuque" = 7;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "ManifiestoCarga" WHERE "CI_IdBuque" = 7;

\echo
\echo ############ 6. IX_ManifiestoCarga_CI_IdAgenteAduanero: manifiestos de un agente
BEGIN; DROP INDEX "IX_ManifiestoCarga_CI_IdAgenteAduanero";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "ManifiestoCarga" WHERE "CI_IdAgenteAduanero" = 7;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "ManifiestoCarga" WHERE "CI_IdAgenteAduanero" = 7;

\echo
\echo ############ 7. IX_DetalleMercancia_CI_IdPartidaArancelaria: mercancia por partida arancelaria
BEGIN; DROP INDEX "IX_DetalleMercancia_CI_IdPartidaArancelaria";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM "DetalleMercancia" WHERE "CI_IdPartidaArancelaria" = 5;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM "DetalleMercancia" WHERE "CI_IdPartidaArancelaria" = 5;

\echo
\echo ############ 8. IX_Buque_CI_IdNaviera: buques de una naviera (tabla de 60 filas)
BEGIN; DROP INDEX "IX_Buque_CI_IdNaviera";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "Buque" WHERE "CI_IdNaviera" = 3;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "Buque" WHERE "CI_IdNaviera" = 3;

\echo
\echo ############ 9. IX_DependenciaAduanera_CI_IdTerminalMaritima: dependencias de una terminal (tabla de 6 filas)
BEGIN; DROP INDEX "IX_DependenciaAduanera_CI_IdTerminalMaritima";
\echo --- A) SIN indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "DependenciaAduanera" WHERE "CI_IdTerminalMaritima" = 1;
ROLLBACK;
\echo --- B) CON indice
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM "DependenciaAduanera" WHERE "CI_IdTerminalMaritima" = 1;
