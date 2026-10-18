#!/bin/bash
# Crea las vistas globales (esquema "global") en los 3 primarios. Correr desde infra/.
set -e
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
for N in 1 2 3; do
  echo "=== nodo $N ==="
  docker compose exec -T nodo$N psql -U postgres -d puerto -v nodo=$N -v pass="$POSTGRES_PASSWORD" < scripts/fdw.sql | tee "fdw_nodo$N.txt"
done
