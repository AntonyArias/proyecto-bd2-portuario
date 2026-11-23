-- 04_stub_cifrado.sql | Funciones base de cifrado (pgcrypto)
-- Permite que el DML masivo del Rol 1 y las pruebas de verificacion funcionen de inmediato.
-- El Rol 3 puede reemplazar el cuerpo de estas funciones manteniendo la firma.
\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE OR REPLACE FUNCTION puerto.cifrar(p_texto TEXT)
RETURNS BYTEA
LANGUAGE sql AS $$
  SELECT pgp_sym_encrypt(
    p_texto,
    coalesce(current_setting('puerto.clave_cifrado', true), 'clave-solo-desarrollo')
  );
$$;

CREATE OR REPLACE FUNCTION puerto.descifrar(p_dato BYTEA)
RETURNS TEXT
LANGUAGE sql AS $$
  SELECT pgp_sym_decrypt(
    p_dato,
    coalesce(current_setting('puerto.clave_cifrado', true), 'clave-solo-desarrollo')
  );
$$;
