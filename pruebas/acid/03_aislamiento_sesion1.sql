-- =====================================================================
-- PRUEBA ACID 3: AISLAMIENTO - SESIÓN 1 (Gana el candado FOR UPDATE)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
\set ON_ERROR_STOP on
SET search_path = puerto, public;

\if :{?espera_seg}
\else
  \set espera_seg 6
\endif

\if :{?id_cont}
\else
  SELECT "CI_IdContenedor" AS id_cont
    FROM puerto."Contenedor"
   WHERE "CI_IdEstadoContenedor" IN (2, 3, 4, 6)
   ORDER BY "CI_IdContenedor"
   LIMIT 1 \gset
\endif

SELECT "CT_NumeroIso" AS iso_cont, "CI_IdEstadoContenedor" AS est_inicial
  FROM puerto."Contenedor"
 WHERE "CI_IdContenedor" = :id_cont \gset

\echo '====================================================================='
\echo ' [SESION 1] Iniciando transaccion de despacho sobre contenedor' :id_cont '(' :iso_cont ')'
\echo '====================================================================='

BEGIN;

SELECT clock_timestamp() AS s1_inicio_bloqueo_for_update;

CALL puerto.sp_despachar_mercancia(
    :id_cont::BIGINT,
    'AA-00001',
    'Despacho concurrente - Sesion 1 (ganadora)',
    NULL
);

\echo '[SESION 1] Fila bloqueada con FOR UPDATE y despacho preparado en transaccion abierta.'
\echo '[SESION 1] Reteniendo candado por' :espera_seg 'segundos para que Sesion 2 choque concurrentemente...'
SELECT pg_sleep(:espera_seg);

COMMIT;

SELECT clock_timestamp() AS s1_commit_confirmado;
\echo '[SESION 1] COMMIT exitoso: contenedor' :iso_cont 'despachado por Sesion 1.'
