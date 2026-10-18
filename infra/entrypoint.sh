#!/bin/bash
# MODO=standby y volumen vacio: clona desde PEER con pg_basebackup (crea standby.signal y primary_conninfo).
# MODO=primario: arranque normal de la imagen oficial (initdb + scripts de /docker-entrypoint-initdb.d).
set -e
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
if [ "$MODO" = "standby" ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[entrypoint] standby: esperando a $PEER para clonar..."
  mkdir -p "$PGDATA"; chown postgres:postgres "$PGDATA"; chmod 700 "$PGDATA"
  until gosu postgres pg_isready -h "$PEER" -U replicador -q; do sleep 2; done
  gosu postgres env PGPASSWORD="$REPL_PASS" pg_basebackup \
      -h "$PEER" -U replicador -D "$PGDATA" -R -X stream -C -S "$SLOT" -c fast
  echo "[entrypoint] clon listo desde $PEER (slot $SLOT)"
fi
exec docker-entrypoint.sh postgres "$@"
