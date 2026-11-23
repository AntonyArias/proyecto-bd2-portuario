#!/bin/bash
# MODO=standby y volumen vacio: clona desde PEER con pg_basebackup (crea standby.signal y primary_conninfo).
# MODO=primario: arranque normal de la imagen oficial (initdb + scripts de /docker-entrypoint-initdb.d).
# Integracion SSL/TLS (Rol 3): prepara /etc/ssl/postgres con dueño postgres y permisos 0600 en server.key.
set -e
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
SSL_DST="/etc/ssl/postgres"

mkdir -p "$SSL_DST"
if [ -s /ssl_src/server.crt ] && [ -s /ssl_src/server.key ]; then
  cp /ssl_src/server.crt "$SSL_DST/server.crt"
  cp /ssl_src/server.key "$SSL_DST/server.key"
  [ -s /ssl_src/ca.crt ] && cp /ssl_src/ca.crt "$SSL_DST/ca.crt"
elif [ ! -s "$SSL_DST/server.crt" ] || [ ! -s "$SSL_DST/server.key" ]; then
  echo "[entrypoint] Generando certificado SSL autofirmado local en $SSL_DST..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$SSL_DST/server.key" -out "$SSL_DST/server.crt" \
    -subj "/C=CR/ST=Limon/O=UCR-IF0010-Portuaria/CN=${HOSTNAME:-localhost}" >/dev/null 2>&1
fi
chown -R postgres:postgres "$SSL_DST"
chmod 700 "$SSL_DST"
chmod 600 "$SSL_DST/server.key"
chmod 644 "$SSL_DST/server.crt"

if [ "$MODO" = "standby" ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[entrypoint] standby: esperando a $PEER para clonar..."
  mkdir -p "$PGDATA"; chown postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"
  until gosu postgres env PGSSLMODE=require pg_isready -h "$PEER" -U replicador -q; do sleep 2; done
  gosu postgres env PGPASSWORD="$REPL_PASS" PGSSLMODE=require pg_basebackup \
      -h "$PEER" -U replicador -D "$PGDATA" -R -X stream -C -S "$SLOT" -c fast
  echo "[entrypoint] clon listo desde $PEER (slot $SLOT)"
fi

if [ -f "$PGDATA/pg_hba.conf" ] && [ -s /seguridad/pg_hba_seguro.conf ]; then
  if ! grep -q "hostnossl" "$PGDATA/pg_hba.conf"; then
    cp /seguridad/pg_hba_seguro.conf "$PGDATA/pg_hba.conf"
    chown postgres:postgres "$PGDATA/pg_hba.conf"
    chmod 600 "$PGDATA/pg_hba.conf"
  fi
fi

exec docker-entrypoint.sh postgres "$@"
