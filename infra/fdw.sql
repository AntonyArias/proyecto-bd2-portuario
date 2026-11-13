-- Vistas globales via postgres_fdw (actualizado a nomenclatura PascalCase / prefijos CI/CT/CB/CD/CF).
-- Se corre con: bash scripts/fdw.sh
-- Obligatorias: -v nodo=N -v pass=<clave>. Opcionales: -v host_fmt='nodo%s' -v port_fmt='5432'
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
  n int; yo int := current_setting('fdw.nodo')::int; t text; src text; h text; p text;
  tabs text[] := ARRAY['ManifiestoCarga','Contenedor','DetalleMercancia','InspeccionTransito'];
  tabs_quoted text;
BEGIN
  SELECT string_agg(quote_ident(x), ',') INTO tabs_quoted FROM unnest(tabs) AS x;
  FOR n IN 1..3 LOOP
    CONTINUE WHEN n = yo;
    h := format(current_setting('fdw.host_fmt'), n) || ',' || format(current_setting('fdw.host_fmt'), n) || 'sb';
    p := format(current_setting('fdw.port_fmt'), n) || ',' || format(current_setting('fdw.port_fmt'), n);
    EXECUTE format('DROP SERVER IF EXISTS nodo%s CASCADE', n);
    EXECUTE format('CREATE SERVER nodo%s FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L, connect_timeout %L, target_session_attrs %L)', n, h, p, 'puerto', '3', 'any');
    EXECUTE format('CREATE USER MAPPING FOR postgres SERVER nodo%s OPTIONS (user %L, password %L)', n, 'postgres', current_setting('fdw.pass'));
    EXECUTE format('DROP SCHEMA IF EXISTS fdw_n%s CASCADE', n);
    EXECUTE format('CREATE SCHEMA fdw_n%s', n);
    EXECUTE format('IMPORT FOREIGN SCHEMA puerto LIMIT TO (%s) FROM SERVER nodo%s INTO fdw_n%s', tabs_quoted, n, n);
  END LOOP;
  FOREACH t IN ARRAY tabs LOOP
    SELECT string_agg(format('SELECT * FROM %s.%I', CASE WHEN k = yo THEN 'puerto' ELSE 'fdw_n'||k END, t), ' UNION ALL ' ORDER BY k)
      INTO src FROM generate_series(1,3) k;
    EXECUTE format('CREATE VIEW global.%I AS %s', t, src);
  END LOOP;
END $$;
SELECT "CI_IdTerminalMaritima" AS terminal, count(*) AS manifiestos FROM global."ManifiestoCarga" GROUP BY 1 ORDER BY 1;
SELECT "CI_IdContenedor"/1000000000 AS nodo, count(*) AS contenedores FROM global."Contenedor" GROUP BY 1 ORDER BY 1;
