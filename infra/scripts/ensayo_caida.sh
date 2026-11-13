#!/bin/bash
# Ensayo de caida con carga concurrente en el fragmento N: ensayo_caida.sh 2 [hilos=6] [segundos=45]
set -e; cd "$(dirname "$0")/.."
N=${1:?uso: ensayo_caida.sh <fragmento 1|2|3> [hilos] [segundos]}; H=${2:-6}; DUR=${3:-45}
set -a; . ./.env; set +a; export PGPASSWORD=$POSTGRES_PASSWORD
P=$(bash scripts/primario_actual.sh $N)
if [ "$P" = "nodo$N" ]; then S=nodo${N}sb; else S=nodo$N; fi
TAG=$(date +%H%M%S); export TAG
mkdir -p ensayos
now() { date +%s.%N; }
dif() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }
echo ">> Ensayo fragmento $N (TAG $TAG): primario=$P standby=$S, $H hilos, $DUR s"
python -u scripts/estres.py $N $H $DUR > ensayos/estres_$TAG.txt 2>&1 &
PY=$!
sleep 4
kill -0 $PY 2>/dev/null || { echo "estres.py no arranco:"; cat ensayos/estres_$TAG.txt; exit 1; }
sleep 6
T_KILL=$(now); docker compose kill $P > /dev/null 2>&1
while docker compose exec -T $S pg_isready -h $P -U postgres -q; do sleep 0.2; done
T_DET=$(now)
bash scripts/failover.sh $N > /dev/null
T_PRO=$(now)
wait $PY || true
RES=$({ echo "CREATE TEMP TABLE a(id bigint); COPY a FROM STDIN;"; tr -d '\r' < acked_n$N.txt; echo '\.'; \
  echo 'SELECT (SELECT count(*) FROM a), (SELECT count(*) FROM a LEFT JOIN puerto."InspeccionTransito" i ON i."CI_IdInspeccionTransito"=a.id WHERE i."CI_IdInspeccionTransito" IS NULL), (SELECT count(*) FROM puerto."InspeccionTransito" WHERE "CT_Observaciones" LIKE '"'estres $TAG %'"');'; } \
  | docker compose exec -T $S psql -U postgres -d puerto -At -q | tail -1)
IFS='|' read CONF PERD TOTAL <<< "$RES"; EXTRA=$((TOTAL-CONF))
DET=$(dif $T_DET $T_KILL); PRO=$(dif $T_PRO $T_DET); ALL=$(dif $T_PRO $T_KILL)
{
echo "=== RESULTADO fragmento $N (ensayo $TAG) ==="
echo "Primario caido: $P | promovido: $S"
echo "Deteccion: ${DET}s | Promocion: ${PRO}s | Total desde la caida: ${ALL}s"
echo "Cliente: $(cat ensayos/estres_$TAG.txt)"
echo "Confirmadas al cliente: $CONF | PERDIDAS: $PERD | en duda (el servidor confirmo, el cliente no lo supo): $EXTRA"
} | tee ensayos/ensayo_${N}_$TAG.txt
[ -f ensayos/resumen.csv ] || echo "ensayo,fragmento,caido,promovido,deteccion_s,promocion_s,total_s,confirmadas,perdidas,en_duda" > ensayos/resumen.csv
echo "$TAG,$N,$P,$S,$DET,$PRO,$ALL,$CONF,$PERD,$EXTRA" >> ensayos/resumen.csv
echo ">> Reintegrando $P como standby..."
bash scripts/rejoin.sh $N
