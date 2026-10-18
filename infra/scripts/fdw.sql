-- Vistas globales via postgres_fdw. Correr en CUALQUIER nodo primario (ve su fragmento local + los 2 remotos):
--   (ver scripts/fdw.sh)
-- Obligatoria: -v pass=<POSTGRES_PASSWORD>. Opcionales: -v host_fmt='nodo%s' -v port_fmt='5432'
-- Recomendado: bash scripts/fdw.sh (carga la clave desde .env y corre los 3 nodos)
\set ON_ERROR_STOP on
\if :{?host_fmt} \else \set host_fmt 'nodo%s' \endif
\if :{?port_fmt} \else \set port_fmt '5432' \endif
\if :{?pass} \else \echo 'ERROR: falta -v pass=... (usa scripts/fdw.sh, que lo toma de .env)' \quit \endif
SET fdw.nodo = :'nodo'; SET fdw.host_fmt = :'host_fmt'; SET fdw.port_fmt = :'port_fmt'; SET fdw.pass = :'pass';
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
DROP SCHEMA IF EXISTS global CASCADE;
CREATE SCHEMA global;
DO $$
DECLARE
  n int; yo int := current_setting('fdw.nodo')::int; t text; src text;
  tabs text[] := ARRAY['manifiesto_carga','contenedor','detalle_mercancia','inspeccion_transito'];
BEGIN
  FOR n IN 1..3 LOOP
    CONTINUE WHEN n = yo;
    EXECUTE format('DROP SERVER IF EXISTS nodo%s CASCADE', n);
    EXECUTE format('CREATE SERVER nodo%s FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L, connect_timeout %L)',
                   n, format(current_setting('fdw.host_fmt'), n), format(current_setting('fdw.port_fmt'), n), 'puerto', '3');
    EXECUTE format('CREATE USER MAPPING FOR postgres SERVER nodo%s OPTIONS (user %L, password %L)', n, 'postgres', current_setting('fdw.pass'));
    EXECUTE format('DROP SCHEMA IF EXISTS fdw_n%s CASCADE', n);
    EXECUTE format('CREATE SCHEMA fdw_n%s', n);
    EXECUTE format('IMPORT FOREIGN SCHEMA puerto LIMIT TO (%s) FROM SERVER nodo%s INTO fdw_n%s', array_to_string(tabs, ','), n, n);
  END LOOP;
  FOREACH t IN ARRAY tabs LOOP
    SELECT string_agg(format('SELECT * FROM %s.%I', CASE WHEN k = yo THEN 'puerto' ELSE 'fdw_n'||k END, t), ' UNION ALL ' ORDER BY k)
      INTO src FROM generate_series(1,3) k;
    EXECUTE format('CREATE VIEW global.%I AS %s', t, src);
  END LOOP;
END $$;
SELECT id_terminal_maritima AS terminal, count(*) AS manifiestos FROM global.manifiesto_carga GROUP BY 1 ORDER BY 1;
SELECT id_contenedor/1000000000 AS nodo, count(*) AS contenedores FROM global.contenedor GROUP BY 1 ORDER BY 1;
