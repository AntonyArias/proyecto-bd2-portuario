cat << 'EOF' > sql/05_seguridad/01_roles_y_seguridad.sql
-- =====================================================================
-- Script de Seguridad, Roles y Cifrado (RBAC + pgcrypto)
-- Proyecto: Sistema de Logística Portuaria y Aduanera
-- Rol 3: Ingeniero Transaccional y de Seguridad
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path = puerto, public;

---------------------------------------------------------------------
-- 1. ASEGURAR EXTENSIÓN Y FUNCIONES DE CIFRADO (pgcrypto)
---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION puerto.cifrar(p_texto TEXT) RETURNS BYTEA
LANGUAGE sql SECURITY DEFINER AS $$ 
    SELECT pgp_sym_encrypt(p_texto, 'portuaria_segura_2026_key'); 
$$;

CREATE OR REPLACE FUNCTION puerto.descifrar(p_dato BYTEA) RETURNS TEXT
LANGUAGE sql SECURITY DEFINER AS $$ 
    SELECT pgp_sym_decrypt(p_dato, 'portuaria_segura_2026_key'); 
$$;

---------------------------------------------------------------------
-- 2. MODELO DE ROLES (RBAC) - PRINCIPIO DE MENOR PRIVILEGIO
---------------------------------------------------------------------
CREATE ROLE rol_lectura NOLOGIN;
CREATE ROLE rol_operador NOLOGIN;
CREATE ROLE rol_admin NOLOGIN;

CREATE USER auditor_user WITH LOGIN PASSWORD 'Auditor2026*' IN ROLE rol_lectura;
CREATE USER operador_user WITH LOGIN PASSWORD 'Operador2026*' IN ROLE rol_operador;
CREATE USER admin_user WITH LOGIN PASSWORD 'Admin2026*' IN ROLE rol_admin;

---------------------------------------------------------------------
-- 3. ASIGNACIÓN DE PRIVILEGIOS DISCRECIONALES (DAC)
---------------------------------------------------------------------
GRANT USAGE ON SCHEMA puerto TO rol_lectura, rol_operador, rol_admin;

GRANT SELECT ON ALL TABLES IN SCHEMA puerto TO rol_lectura;
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto GRANT SELECT ON TABLES TO rol_lectura;

GRANT SELECT, INSERT, UPDATE ON 
    manifiesto_carga, contenedor, detalle_mercancia, inspeccion_transito 
TO rol_operador;

GRANT SELECT ON 
    pais, tipo_contenedor, estado_contenedor, tipo_inspeccion, 
    partida_arancelaria, terminal_maritima, dependencia_aduanera, 
    naviera, buque, agente_aduanero 
TO rol_operador;

ALTER DEFAULT PRIVILEGES IN SCHEMA puerto GRANT SELECT, INSERT, UPDATE ON TABLES TO rol_operador;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA puerto TO rol_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA puerto TO rol_admin, rol_operador;
ALTER DEFAULT PRIVILEGES IN SCHEMA puerto GRANT ALL PRIVILEGES ON TABLES TO rol_admin;

---------------------------------------------------------------------
-- 4. VISTA SEGURA DE ADMINISTRACIÓN CON DATOS DESCIFRADOS
---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_agente_seguro AS
SELECT 
    id_agente_aduanero,
    codigo_licencia,
    nombre,
    apellidos,
    correo,
    puerto.descifrar(cedula_enc) AS cedula,
    puerto.descifrar(telefono_enc) AS telefono,
    activo
FROM agente_aduanero;

GRANT SELECT ON vista_agente_seguro TO rol_admin;
REVOKE SELECT ON agente_aduanero FROM rol_operador, rol_lectura;
EOF
