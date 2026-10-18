#!/bin/bash
# Promueve el standby del fragmento N: failover.sh 2
N=$1; S=nodo${N}sb
echo "Promoviendo $S a las $(date +%T)"
docker compose exec -T $S psql -U postgres -Atc "select pg_promote(wait_seconds => 30)"
echo "Listo a las $(date +%T). Nuevo primario: $(bash "$(dirname "$0")/primario_actual.sh" $N)"
