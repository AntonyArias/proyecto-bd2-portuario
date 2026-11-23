-- =====================================================================
-- PRUEBA ACID 4: DURABILIDAD - PASO 2 (Verificación tras caída y recovery WAL)
-- Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- =====================================================================

\pset pager off
\set ON_ERROR_STOP on
SET search_path = puerto, public;

\if :{?num_man_dur}
\else
  SELECT "CT_NumeroManifiesto" AS num_man_dur
    FROM puerto."ManifiestoCarga"
   WHERE "CT_NumeroManifiesto" LIKE 'MAN-T1-9%'
   ORDER BY "CI_IdManifiestoCarga" DESC
   LIMIT 1 \gset
\endif

\echo '====================================================================='
\echo ' [DURABILIDAD - PASO 2] Verificando persistencia post-crash de:' :'num_man_dur'
\echo '====================================================================='

SELECT m."CI_IdManifiestoCarga",
       m."CT_NumeroManifiesto",
       c."CI_IdContenedor",
       c."CT_NumeroIso",
       d."CT_Descripcion",
       d."CD_PesoKg",
       (SELECT count(*) FROM puerto."InspeccionTransito" i WHERE i."CI_IdContenedor" = c."CI_IdContenedor") AS inspecciones_registradas,
       CASE
         WHEN m."CI_IdManifiestoCarga" IS NOT NULL
          AND c."CI_IdContenedor" IS NOT NULL
          AND d."CI_IdDetalleMercancia" IS NOT NULL
         THEN 'OK - DURABILIDAD DEMOSTRADA (DATOS INTACTOS TRAS SIGKILL)'
         ELSE 'FALLO DE DURABILIDAD'
       END AS resultado_durabilidad
  FROM puerto."ManifiestoCarga" m
  JOIN puerto."Contenedor" c USING ("CI_IdManifiestoCarga")
  JOIN puerto."DetalleMercancia" d USING ("CI_IdContenedor")
 WHERE m."CT_NumeroManifiesto" = :'num_man_dur';
