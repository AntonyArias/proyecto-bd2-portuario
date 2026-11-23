-- =====================================================================
-- Script de Seguridad, Roles (RBAC), Cifrado (pgcrypto) y RLS
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- Estándar: Tablas PascalCase y columnas CI_/CT_/CB_/CD_/CF_
-- Uso (variables tomadas desde infra/.env, NUNCA quemadas en el repo):
--   psql -U postgres -d puerto -v ON_ERROR_STOP=1 \
--     -v enc_key="$ENC_KEY" \
--     -v auditor_pass="$AUDITOR_PASS" \
--     -v operador_pass="$OPERADOR_PASS" \
--     -v admin_pass="$ADMIN_PASS" \
--     -f sql/05_seguridad/01_roles_y_seguridad.sql
-- =====================================================================

\set ON_ERROR_STOP on

\if :{?enc_key}
\else
  \echo 'ERROR: falta -v enc_key=... (ejecuta bash sql/aplicar_rol3.sh para cargarlo desde infra/.env)'
  \quit 1
\endif
\if :{?auditor_pass}
\else
  \echo 'ERROR: falta -v auditor_pass=... (ejecuta bash sql/aplicar_rol3.sh para cargarlo desde infra/.env)'
  \quit 1
\endif
\if :{?operador_pass}
\else
  \echo 'ERROR: falta -v operador_pass=... (ejecuta bash sql/aplicar_rol3.sh para cargarlo desde infra/.env)'
  \quit 1
\endif
\if :{?admin_pass}
\else
  \echo 'ERROR: falta -v admin_pass=... (ejecuta bash sql/aplicar_rol3.sh para cargarlo desde infra/.env)'
  \quit 1
\endif

SET search_path = puerto, public;
SET password_encryption = 'scram-sha-256';

SET app.setup_enc_key       = :'enc_key';
SET app.setup_auditor_pass  = :'auditor_pass';
SET app.setup_operador_pass = :'operador_pass';
SET app.setup_admin_pass    = :'admin_pass';

---------------------------------------------------------------------
-- 1. ALMACÉN INTERNO PROTEGIDO DE LLAVE Y MIGRACIÓN DE CIFRADO (pgcrypto)
---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS seguridad_interna;
REVOKE ALL ON SCHEMA seguridad_interna FROM PUBLIC;

CREATE TABLE IF NOT EXISTS seguridad_interna."ConfigCifrado" (
    "CI_Id"           SMALLINT PRIMARY KEY DEFAULT 1 CHECK ("CI_Id" = 1),
    "CT_Llave"        TEXT NOT NULL,
    "CF_ActualizadoEn" TIMESTAMPTZ NOT NULL DEFAULT now()
);
REVOKE ALL ON ALL TABLES IN SCHEMA seguridad_interna FROM PUBLIC;

-- Si los datos existentes se cargaron con el stub 'clave-solo-desarrollo' (o llave previa),
-- recifrarlos atómicamente con la llave real de infra/.env usando AES-256.
DO $$
DECLARE
    v_nueva_llave   TEXT := current_setting('app.setup_enc_key');
    v_llave_previa  TEXT;
    v_llave_origen  TEXT := NULL;
    v_muestra       BYTEA;
    v_prueba        TEXT;
BEGIN
    IF v_nueva_llave IS NULL OR length(btrim(v_nueva_llave)) < 8 THEN
        RAISE EXCEPTION 'La llave ENC_KEY debe tener al menos 8 caracteres.';
    END IF;

    SELECT "CT_Llave" INTO v_llave_previa
      FROM seguridad_interna."ConfigCifrado"
     WHERE "CI_Id" = 1;

    SELECT "CT_CedulaEnc" INTO v_muestra
      FROM puerto."AgenteAduanero"
     LIMIT 1;

    IF v_muestra IS NOT NULL THEN
        BEGIN
            v_prueba := pgp_sym_decrypt(v_muestra, v_nueva_llave);
            v_llave_origen := NULL;
        EXCEPTION WHEN OTHERS THEN
            IF v_llave_previa IS NOT NULL THEN
                BEGIN
                    v_prueba := pgp_sym_decrypt(v_muestra, v_llave_previa);
                    v_llave_origen := v_llave_previa;
                EXCEPTION WHEN OTHERS THEN
                    v_llave_origen := NULL;
                END;
            END IF;

            IF v_llave_origen IS NULL THEN
                BEGIN
                    v_prueba := pgp_sym_decrypt(v_muestra, 'clave-solo-desarrollo');
                    v_llave_origen := 'clave-solo-desarrollo';
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'No fue posible migrar los datos cifrados existentes: llave previa desconocida.';
                END;
            END IF;
        END;

        IF v_llave_origen IS NOT NULL THEN
            RAISE NOTICE 'Migrando columnas sensibles desde llave previa hacia ENC_KEY (AES-256)...';

            UPDATE puerto."AgenteAduanero"
               SET "CT_CedulaEnc"   = pgp_sym_encrypt(pgp_sym_decrypt("CT_CedulaEnc", v_llave_origen), v_nueva_llave, 'cipher-algo=aes256'),
                   "CT_TelefonoEnc" = pgp_sym_encrypt(pgp_sym_decrypt("CT_TelefonoEnc", v_llave_origen), v_nueva_llave, 'cipher-algo=aes256');

            UPDATE puerto."DetalleMercancia"
               SET "CT_ValorDeclaradoEnc"   = pgp_sym_encrypt(pgp_sym_decrypt("CT_ValorDeclaradoEnc", v_llave_origen), v_nueva_llave, 'cipher-algo=aes256'),
                   "CT_ValorArancelarioEnc" = pgp_sym_encrypt(pgp_sym_decrypt("CT_ValorArancelarioEnc", v_llave_origen), v_nueva_llave, 'cipher-algo=aes256');
        END IF;
    END IF;

    INSERT INTO seguridad_interna."ConfigCifrado" ("CI_Id", "CT_Llave", "CF_ActualizadoEn")
    VALUES (1, v_nueva_llave, now())
    ON CONFLICT ("CI_Id") DO UPDATE
       SET "CT_Llave"         = EXCLUDED."CT_Llave",
           "CF_ActualizadoEn" = now();
END;
$$;

-- Reemplazar el cuerpo de los stubs de 04_stub_cifrado.sql SIN cambiar nombre ni firma
CREATE OR REPLACE FUNCTION puerto.cifrar(p_texto TEXT) RETURNS BYTEA
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = puerto, seguridad_interna, public, pg_temp
AS $$
DECLARE
    v_llave TEXT;
BEGIN
    IF p_texto IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT "CT_Llave" INTO STRICT v_llave
      FROM seguridad_interna."ConfigCifrado"
     WHERE "CI_Id" = 1;
    RETURN pgp_sym_encrypt(p_texto, v_llave, 'cipher-algo=aes256');
END;
$$;

CREATE OR REPLACE FUNCTION puerto.descifrar(p_dato BYTEA) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = puerto, seguridad_interna, public, pg_temp
AS $$
DECLARE
    v_llave TEXT;
BEGIN
    IF p_dato IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT "CT_Llave" INTO STRICT v_llave
      FROM seguridad_interna."ConfigCifrado"
     WHERE "CI_Id" = 1;
    RETURN pgp_sym_decrypt(p_dato, v_llave);
END;
$$;

---------------------------------------------------------------------
-- 2. MODELO DE ROLES (RBAC) Y USUARIOS DE EJEMPLO (IDEMPOTENTE)
---------------------------------------------------------------------
DO $$
DECLARE
    v_auditor_pass  TEXT := current_setting('app.setup_auditor_pass');
    v_operador_pass TEXT := current_setting('app.setup_operador_pass');
    v_admin_pass    TEXT := current_setting('app.setup_admin_pass');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_lectura') THEN
        CREATE ROLE rol_lectura NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_operador') THEN
        CREATE ROLE rol_operador NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rol_admin') THEN
        CREATE ROLE rol_admin NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditor_user') THEN
        EXECUTE format('CREATE ROLE auditor_user WITH LOGIN PASSWORD %L IN ROLE rol_lectura', v_auditor_pass);
    ELSE
        EXECUTE format('ALTER ROLE auditor_user WITH LOGIN PASSWORD %L', v_auditor_pass);
        GRANT rol_lectura TO auditor_user;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'operador_user') THEN
        EXECUTE format('CREATE ROLE operador_user WITH LOGIN PASSWORD %L IN ROLE rol_operador', v_operador_pass);
    ELSE
        EXECUTE format('ALTER ROLE operador_user WITH LOGIN PASSWORD %L', v_operador_pass);
        GRANT rol_operador TO operador_user;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_user') THEN
        EXECUTE format('CREATE ROLE admin_user WITH LOGIN PASSWORD %L IN ROLE rol_admin', v_admin_pass);
    ELSE
        EXECUTE format('ALTER ROLE admin_user WITH LOGIN PASSWORD %L', v_admin_pass);
        GRANT rol_admin TO admin_user;
    END IF;
END;
$$;

-- Limpiar secretos de sesión inmediatamente
RESET app.setup_enc_key;
RESET app.setup_auditor_pass;
RESET app.setup_operador_pass;
RESET app.setup_admin_pass;

---------------------------------------------------------------------
-- 3. VISTAS SEGURAS DE DESCIFRADO (EXCLUSIVAS PARA rol_admin)
---------------------------------------------------------------------
CREATE OR REPLACE VIEW puerto."VistaAgenteSeguro" AS
SELECT
    "CI_IdAgenteAduanero",
    "CT_CodigoLicencia",
    "CT_Nombre",
    "CT_Apellidos",
    "CT_Correo",
    puerto.descifrar("CT_CedulaEnc")   AS "CT_Cedula",
    puerto.descifrar("CT_TelefonoEnc") AS "CT_Telefono",
    "CB_Activo"
FROM puerto."AgenteAduanero";

CREATE OR REPLACE VIEW puerto."VistaDetalleMercanciaSeguro" AS
SELECT
    d."CI_IdDetalleMercancia",
    d."CI_IdContenedor",
    c."CT_NumeroIso",
    d."CI_IdPartidaArancelaria",
    p."CT_CodigoHs",
    d."CT_Descripcion",
    d."CI_Cantidad",
    d."CD_PesoKg",
    puerto.descifrar(d."CT_ValorDeclaradoEnc")::NUMERIC(14,2)   AS "CD_ValorDeclaradoUsd",
    puerto.descifrar(d."CT_ValorArancelarioEnc")::NUMERIC(14,2) AS "CD_ValorArancelarioUsd",
    d."CT_EstadoInventario"
FROM puerto."DetalleMercancia" d
JOIN puerto."Contenedor" c
  ON c."CI_IdContenedor" = d."CI_IdContenedor"
JOIN puerto."PartidaArancelaria" p
  ON p."CI_IdPartidaArancelaria" = d."CI_IdPartidaArancelaria";

---------------------------------------------------------------------
-- 4. CONTROL DE ACCESO GRANULAR - PRINCIPIO DE MENOR PRIVILEGIO
---------------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA seguridad_interna FROM PUBLIC, rol_lectura, rol_operador, rol_admin;
REVOKE ALL ON ALL TABLES IN SCHEMA seguridad_interna FROM PUBLIC, rol_lectura, rol_operador, rol_admin;

REVOKE ALL ON SCHEMA puerto FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA puerto FROM PUBLIC, rol_lectura, rol_operador, rol_admin;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA puerto FROM PUBLIC, rol_lectura, rol_operador, rol_admin;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA puerto FROM PUBLIC, rol_lectura, rol_operador, rol_admin;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA puerto FROM PUBLIC, rol_lectura, rol_operador, rol_admin;

GRANT USAGE ON SCHEMA puerto TO rol_lectura, rol_operador, rol_admin;

-- 4.1 rol_lectura: solo lectura sobre tablas base (las columnas *_Enc se ven cifradas/ilegibles en BYTEA)
GRANT SELECT ON
    puerto."Pais",
    puerto."TipoContenedor",
    puerto."EstadoContenedor",
    puerto."TipoInspeccion",
    puerto."PartidaArancelaria",
    puerto."TerminalMaritima",
    puerto."DependenciaAduanera",
    puerto."Naviera",
    puerto."Buque",
    puerto."AgenteAduanero",
    puerto."ManifiestoCarga",
    puerto."Contenedor",
    puerto."DetalleMercancia",
    puerto."InspeccionTransito"
TO rol_lectura;

-- 4.2 rol_operador: lectura en catálogos/comunes; SELECT, INSERT, UPDATE (SIN DELETE) en tablas operativas
GRANT SELECT ON
    puerto."Pais",
    puerto."TipoContenedor",
    puerto."EstadoContenedor",
    puerto."TipoInspeccion",
    puerto."PartidaArancelaria",
    puerto."TerminalMaritima",
    puerto."DependenciaAduanera",
    puerto."Naviera",
    puerto."Buque",
    puerto."AgenteAduanero"
TO rol_operador;

GRANT SELECT, INSERT, UPDATE ON
    puerto."ManifiestoCarga",
    puerto."Contenedor",
    puerto."DetalleMercancia",
    puerto."InspeccionTransito"
TO rol_operador;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA puerto TO rol_operador;

-- 4.3 rol_admin: administración completa de tablas base, secuencias y vistas de descifrado
GRANT SELECT, INSERT, UPDATE, DELETE ON
    puerto."Pais",
    puerto."TipoContenedor",
    puerto."EstadoContenedor",
    puerto."TipoInspeccion",
    puerto."PartidaArancelaria",
    puerto."TerminalMaritima",
    puerto."DependenciaAduanera",
    puerto."Naviera",
    puerto."Buque",
    puerto."AgenteAduanero",
    puerto."ManifiestoCarga",
    puerto."Contenedor",
    puerto."DetalleMercancia",
    puerto."InspeccionTransito"
TO rol_admin;

GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA puerto TO rol_admin;

-- Vistas con datos descifrados: ESTRICTAMENTE solo para rol_admin
GRANT SELECT ON
    puerto."VistaAgenteSeguro",
    puerto."VistaDetalleMercanciaSeguro"
TO rol_admin;

-- Bitácora de auditoría: solo lectura para rol_admin (inmutable ante borrados/ediciones)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'puerto' AND table_name = 'BitacoraAuditoria'
    ) THEN
        GRANT SELECT ON puerto."BitacoraAuditoria" TO rol_admin;
    END IF;
END;
$$;

-- 4.4 Permisos sobre funciones criptográficas y procedimientos almacenados
GRANT EXECUTE ON FUNCTION puerto.cifrar(TEXT) TO rol_operador, rol_admin;
GRANT EXECUTE ON FUNCTION puerto.descifrar(BYTEA) TO rol_admin;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'puerto' AND p.proname = 'sp_ingresar_manifiesto') THEN
        GRANT EXECUTE ON PROCEDURE puerto.sp_ingresar_manifiesto(
            SMALLINT, CHAR(7), VARCHAR(12), VARCHAR(20), VARCHAR(60), TIMESTAMPTZ, JSONB, BIGINT
        ) TO rol_operador, rol_admin;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'puerto' AND p.proname = 'sp_despachar_mercancia') THEN
        GRANT EXECUTE ON PROCEDURE puerto.sp_despachar_mercancia(
            BIGINT, VARCHAR(12), TEXT, BIGINT
        ) TO rol_operador, rol_admin;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'puerto' AND p.proname = 'sp_registrar_inspeccion') THEN
        GRANT EXECUTE ON PROCEDURE puerto.sp_registrar_inspeccion(
            SMALLINT, BIGINT, SMALLINT, INT, VARCHAR(12), TEXT
        ) TO rol_operador, rol_admin;
    END IF;
END;
$$;

-- Si existe el esquema global (postgres_fdw), permitir lectura global solo a rol_admin
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'global') THEN
        REVOKE ALL ON SCHEMA global FROM PUBLIC, rol_lectura, rol_operador;
        GRANT USAGE ON SCHEMA global TO rol_admin;
        GRANT SELECT ON ALL TABLES IN SCHEMA global TO rol_admin;
    END IF;
END;
$$;

-- Privilegios por defecto para objetos futuros en esquema puerto
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto REVOKE ALL ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto GRANT SELECT ON TABLES TO rol_lectura;
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rol_admin;

---------------------------------------------------------------------
-- 5. ROW-LEVEL SECURITY (RLS) EN ManifiestoCarga (DEFENSA EN PROFUNDIDAD)
--    Si se fija SET app.terminal_asignada = '<id>', rol_operador queda
--    restringido exclusivamente a los manifiestos de esa terminal.
---------------------------------------------------------------------
ALTER TABLE puerto."ManifiestoCarga" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_manifiesto_admin ON puerto."ManifiestoCarga";
CREATE POLICY pol_manifiesto_admin
    ON puerto."ManifiestoCarga"
    FOR ALL
    TO rol_admin
    USING (true)
    WITH CHECK (true);

DROP POLICY IF EXISTS pol_manifiesto_lectura ON puerto."ManifiestoCarga";
CREATE POLICY pol_manifiesto_lectura
    ON puerto."ManifiestoCarga"
    FOR SELECT
    TO rol_lectura
    USING (true);

DROP POLICY IF EXISTS pol_manifiesto_operador_terminal ON puerto."ManifiestoCarga";
CREATE POLICY pol_manifiesto_operador_terminal
    ON puerto."ManifiestoCarga"
    FOR ALL
    TO rol_operador
    USING (
        "CI_IdTerminalMaritima" = COALESCE(
            NULLIF(current_setting('app.terminal_asignada', true), '')::SMALLINT,
            "CI_IdTerminalMaritima"
        )
    )
    WITH CHECK (
        "CI_IdTerminalMaritima" = COALESCE(
            NULLIF(current_setting('app.terminal_asignada', true), '')::SMALLINT,
            "CI_IdTerminalMaritima"
        )
    );
