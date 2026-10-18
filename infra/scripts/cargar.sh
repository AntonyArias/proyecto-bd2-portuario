#!/bin/bash
# Carga DDL + DML + verificacion en los 3 primarios. Correr desde infra/ con los 6 contenedores arriba.
set -e
for N in 1 2 3; do
  echo "=== nodo $N ==="
  docker compose exec -T nodo$N psql -U postgres -d puerto -q -v nodo=$N -f /datos/01_ddl.sql
  docker compose exec -T nodo$N psql -U postgres -d puerto -q -v nodo=$N -f /datos/02_dml.sql
  docker compose exec -T nodo$N psql -U postgres -d puerto -v nodo=$N -f /datos/03_verificacion.sql | tee "verif_nodo$N.txt"
done
