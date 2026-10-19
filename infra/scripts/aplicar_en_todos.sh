#!/bin/bash
# Corre un .sql en el primario ACTUAL de cada fragmento: aplicar_en_todos.sh ruta/archivo.sql
set -e; cd "$(dirname "$0")/.."
[ -f "$1" ] || { echo "No existe $1"; exit 1; }
for N in 1 2 3; do
  P=$(bash scripts/primario_actual.sh $N)
  echo "=== fragmento $N ($P) ==="
  docker compose exec -T $P psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo=$N < "$1"
done
