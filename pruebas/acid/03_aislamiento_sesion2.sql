-- =====================================================================
-- PRUEBA ACID 3: AISLAMIENTO - SESIÓN 2 (Espera candado y evita doble despacho)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Uso: Correr en la Terminal 2 mientras la Sesión 1 mantiene la transacción abierta.
-- =====================================================================

\pset pager off
SET search_path = puerto, public;

-- Gracias a MVCC (READ COMMITTED), mientras Sesión 1 no ha hecho COMMIT,
-- esta consulta sigue viendo el MISMO contenedor disponible y apunta al mismo ID.
\if :{?id_cont}
\else
  SELECT id_contenedor AS id_cont
    FROM puerto.contenedor
   WHERE id_estado_contenedor IN (2, 3, 4, 6)
   ORDER BY id_contenedor
   LIMIT 1 \gset
\endif

SELECT numero_iso AS iso_cont, id_estado_contenedor AS est_visible_mvcc
  FROM puerto.contenedor
 WHERE id_contenedor = :id_cont \gset

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
SELECT c.id_contenedor,
       c.numero_iso,
       ec.codigo AS estado_final,
       (SELECT count(*)
          FROM puerto.inspeccion_transito i
         WHERE i.id_contenedor = c.id_contenedor
           AND i.id_tipo_inspeccion = 5
           AND i.observaciones LIKE 'Despacho concurrente%') AS despachos_concurrentes_aplicados,
       CASE
         WHEN c.id_estado_contenedor = 7
          AND (SELECT count(*)
                 FROM puerto.inspeccion_transito i
                WHERE i.id_contenedor = c.id_contenedor
                  AND i.id_tipo_inspeccion = 5
                  AND i.observaciones LIKE 'Despacho concurrente%') = 1
         THEN 'OK - AISLAMIENTO DEMOSTRADO (1 SOLO DESPACHO, CERO CONDICION DE CARRERA)'
         ELSE 'FALLO DE AISLAMIENTO'
       END AS resultado_aislamiento
  FROM puerto.contenedor c
  JOIN puerto.estado_contenedor ec USING (id_estado_contenedor)
 WHERE c.id_contenedor = :id_cont;

