-- =====================================================================
-- PRUEBA ACID 3: AISLAMIENTO - SESIÓN 1 (Gana el candado FOR UPDATE)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Uso en defensa con 2 terminales (o vía bash pruebas/acid/03_aislamiento_demo.sh):
--   1. Correr este script en la Terminal 1.
--   2. En los siguientes 6 segundos correr 03_aislamiento_sesion2.sql en la Terminal 2.
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
  SELECT id_contenedor AS id_cont
    FROM puerto.contenedor
   WHERE id_estado_contenedor IN (2, 3, 4, 6)
   ORDER BY id_contenedor
   LIMIT 1 \gset
\endif

SELECT numero_iso AS iso_cont, id_estado_contenedor AS est_inicial
  FROM puerto.contenedor
 WHERE id_contenedor = :id_cont \gset

\echo '====================================================================='
\echo ' [SESION 1] Iniciando transaccion de despacho sobre contenedor' :id_cont '(' :iso_cont ')'
\echo '====================================================================='

BEGIN;

SELECT clock_timestamp() AS s1_inicio_bloqueo_for_update;

-- sp_despachar_mercancia ejecuta internamente SELECT ... FOR UPDATE OF c
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

