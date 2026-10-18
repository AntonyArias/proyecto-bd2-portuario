#!/bin/bash
# Imprime cual contenedor (nodoN o nodoNsb) es el primario del fragmento N: primario_actual.sh 2
N=$1
for h in nodo$N nodo${N}sb; do
  r=$(docker compose exec -T $h psql -U postgres -d puerto -Atc "select pg_is_in_recovery()" 2>/dev/null || true)
  [ "$r" = "f" ] && echo $h && exit 0
done
exit 1
