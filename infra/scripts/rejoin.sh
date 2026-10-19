#!/bin/bash
# Reintegra el nodo caido del fragmento N como standby del primario actual: rejoin.sh 2
set -e; cd "$(dirname "$0")/.."
N=$1
P=$(bash scripts/primario_actual.sh $N) || { echo "El fragmento $N no tiene primario vivo"; exit 1; }
if [ "$P" = "nodo$N" ]; then D=nodo${N}sb; else D=nodo$N; fi
echo "Primario actual: $P. Reintegrando $D como standby..."
docker compose rm -sf $D
docker volume rm portuaria_${D}_data
if [ "$D" = "nodo$N" ]; then
  env "N${N}_MODO=standby" "N${N}_PEER=$P" docker compose up -d $D
else
  docker compose up -d $D
fi
echo "Esperando a que $D quede en streaming..."
s=0
for i in $(seq 1 40); do
  s=$(docker compose exec -T $P psql -U postgres -Atc "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null || echo 0)
  [ "$s" = "1" ] && break
  sleep 3
done
[ "$s" = "1" ] || { echo "No llego a streaming; revisa: docker compose logs $D"; exit 1; }
bash scripts/sincrona.sh $N on
