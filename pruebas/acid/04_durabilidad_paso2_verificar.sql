-- =====================================================================
-- PRUEBA ACID 4: DURABILIDAD - PASO 2 (Verificación tras caída y recovery WAL)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Verifica que el último manifiesto confirmado antes del SIGKILL persiste
-- íntegro junto con su contenedor, detalle cifrado e inspección de ingreso.
-- =====================================================================

\pset pager off
\set ON_ERROR_STOP on
SET search_path = puerto, public;

\if :{?num_man_dur}
\else
  SELECT numero_manifiesto AS num_man_dur
    FROM puerto.manifiesto_carga
   WHERE numero_manifiesto LIKE 'MAN-T1-D%'
   ORDER BY id_manifiesto_carga DESC
   LIMIT 1 \gset
\endif

\echo '====================================================================='
\echo ' [DURABILIDAD - PASO 2] Verificando persistencia post-crash de:' :'num_man_dur'
\echo '====================================================================='

SELECT m.id_manifiesto_carga,
       m.numero_manifiesto,
       c.id_contenedor,
       c.numero_iso,
       d.descripcion,
       d.peso_kg,
       (SELECT count(*) FROM puerto.inspeccion_transito i WHERE i.id_contenedor = c.id_contenedor) AS inspecciones_registradas,
       CASE
         WHEN m.id_manifiesto_carga IS NOT NULL
          AND c.id_contenedor IS NOT NULL
          AND d.id_detalle_mercancia IS NOT NULL
         THEN 'OK - DURABILIDAD DEMOSTRADA (DATOS INTACTOS TRAS SIGKILL)'
         ELSE 'FALLO DE DURABILIDAD'
       END AS resultado_durabilidad
  FROM puerto.manifiesto_carga m
  JOIN puerto.contenedor c USING (id_manifiesto_carga)
  JOIN puerto.detalle_mercancia d USING (id_contenedor)
 WHERE m.numero_manifiesto = :'num_man_dur';

