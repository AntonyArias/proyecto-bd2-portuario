#!/bin/bash
# Promueve el standby vivo del fragmento N cuando su primario cayo: failover.sh 2
set -e; cd "$(dirname "$0")/.."
N=$1
if P=$(bash scripts/primario_actual.sh $N 2>/dev/null); then
  echo "El fragmento $N ya tiene primario vivo ($P); nada que promover."; exit 1
fi
S=""
for h in nodo$N nodo${N}sb; do
  r=$(docker compose exec -T $h psql -U postgres -d puerto -Atc "select pg_is_in_recovery()" 2>/dev/null || true)
  [ "$r" = "t" ] && S=$h
done
[ -n "$S" ] || { echo "No hay standby vivo en el fragmento $N"; exit 1; }
echo "Promoviendo $S a las $(date +%T)"
docker compose exec -T $S psql -U postgres -Atc "select pg_promote(wait_seconds => 30)"
echo "Listo a las $(date +%T). Nuevo primario: $S"
# con sincrona activa y sin standby, el primario bloquearia las escrituras
bash scripts/sincrona.sh $N off
