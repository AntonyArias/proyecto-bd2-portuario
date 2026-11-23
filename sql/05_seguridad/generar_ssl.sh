#!/bin/bash
# =====================================================================
# Genera certificados SSL/TLS locales para los 6 nodos PostgreSQL 16.
# Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
# Nota de secretos: Las llaves privadas (*.key) van a infra/ssl/ y están
# ignoradas por .gitignore (NUNCA se suben a Git).
# Uso: bash sql/05_seguridad/generar_ssl.sh [directorio_destino]
# =====================================================================
set -e

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SSL_DIR="${1:-$ROOT_DIR/infra/ssl}"

mkdir -p "$SSL_DIR"
cd "$SSL_DIR"

cat > openssl_san.cnf << 'EOF'
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[dn]
C  = CR
ST = Limon
L  = Moin
O  = UCR-IF0010-Portuaria
OU = Seguridad-Rol3
CN = portuaria-pg-cluster

[req_ext]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = localhost
DNS.2 = nodo1
DNS.3 = nodo1sb
DNS.4 = nodo2
DNS.5 = nodo2sb
DNS.6 = nodo3
DNS.7 = nodo3sb
IP.1  = 127.0.0.1
EOF

# 1. Autoridad Certificadora local (CA) - rutas relativas compatibles con Win64/MinGW/Linux
openssl genrsa -out ca.key 2048 2>/dev/null
MSYS_NO_PATHCONV=1 openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/C=CR/ST=Limon/O=UCR-IF0010-Portuaria/CN=Portuaria-Root-CA" \
  -out ca.crt

# 2. Llave privada y CSR del servidor PostgreSQL con SANs de los 6 nodos
openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key \
  -config openssl_san.cnf \
  -out server.csr

# 3. Certificado de servidor firmado por la CA local (validez 825 días)
openssl x509 -req -in server.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 -sha256 \
  -extfile openssl_san.cnf -extensions req_ext 2>/dev/null

chmod 600 ca.key server.key
chmod 644 ca.crt server.crt

echo "OK: Certificados SSL/TLS generados en $SSL_DIR:"
openssl x509 -in server.crt -noout -subject -issuer -dates -ext subjectAltName
