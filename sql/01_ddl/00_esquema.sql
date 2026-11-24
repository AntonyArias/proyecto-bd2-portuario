-- 00_esquema.sql | Esquema puerto y extension pgcrypto
-- Uso: psql -U postgres -d puerto -p 544N -f sql/01_ddl/00_esquema.sql
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS puerto;
SET search_path = puerto, public;
