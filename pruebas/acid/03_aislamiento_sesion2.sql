-- =====================================================================
-- PRUEBA ACID 3: AISLAMIENTO - SESIÓN 2 (Espera candado y evita doble despacho)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

\if :{?id_cont}
\else
  SELECT "CI_IdContenedor" AS id_cont
    FROM puerto."Contenedor"
   WHERE "CI_IdEstadoContenedor" IN (2, 3, 4, 6)
   ORDER BY "CI_IdContenedor"
   LIMIT 1 \gset
\endif

SELECT "CT_NumeroIso" AS iso_cont, "CI_IdEstadoContenedor" AS est_visible_mvcc
  FROM puerto."Contenedor"
 WHERE "CI_IdContenedor" = :id_cont \gset

\echo '====================================================================='
\echo ' [SESION 2] Intentando despachar SIMULTANEAMENTE el contenedor' :id_cont '(' :iso_cont ')'
\echo '            Estado aun visible por snapshot MVCC antes del COMMIT de S1:' :est_visible_mvcc
\echo '====================================================================='

SELECT clock_timestamp() AS s2_antes_de_llamar_sp \gset
\echo '[SESION 2] Hora de intento (queda bloqueada en FOR UPDATE esperando a Sesion 1):' :'s2_antes_de_llamar_sp'

\set ON_ERROR_STOP off

CALL puerto.sp_despachar_mercancia(
    :id_cont::BIGINT,
    'AA-00002',
    'Despacho concurrente - Sesion 2 (debe ser rechazado)',
    NULL
);

\set ON_ERROR_STOP on

SELECT clock_timestamp() AS s2_despues_de_desbloqueo \gset
\echo '[SESION 2] Hora en que se libero el candado y se rechazo el doble despacho:' :'s2_despues_de_desbloqueo'

\echo ''
\echo '--- Verificacion final de Aislamiento sobre el contenedor' :id_cont '(' :iso_cont ') ---'
SELECT c."CI_IdContenedor",
       c."CT_NumeroIso",
       ec."CT_Codigo" AS estado_final,
       (SELECT count(*)
          FROM puerto."InspeccionTransito" i
         WHERE i."CI_IdContenedor" = c."CI_IdContenedor"
           AND i."CI_IdTipoInspeccion" = 5
           AND i."CT_Observaciones" LIKE 'Despacho concurrente%') AS despachos_concurrentes_aplicados,
       CASE
         WHEN c."CI_IdEstadoContenedor" = 7
          AND (SELECT count(*)
                 FROM puerto."InspeccionTransito" i
                WHERE i."CI_IdContenedor" = c."CI_IdContenedor"
                  AND i."CI_IdTipoInspeccion" = 5
                  AND i."CT_Observaciones" LIKE 'Despacho concurrente%') = 1
         THEN 'OK - AISLAMIENTO DEMOSTRADO (1 SOLO DESPACHO, CERO CONDICION DE CARRERA)'
         ELSE 'FALLO DE AISLAMIENTO'
       END AS resultado_aislamiento
  FROM puerto."Contenedor" c
  JOIN puerto."EstadoContenedor" ec USING ("CI_IdEstadoContenedor")
 WHERE c."CI_IdContenedor" = :id_cont;
