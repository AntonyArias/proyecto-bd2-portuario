#!/bin/bash
# Estado de replicacion, retardo y conteos primario vs standby de cada fragmento. Correr desde infra/.
cd "$(dirname "$0")/.."
CONTEOS="select (select count(*) from puerto.manifiesto_carga)||','||(select count(*) from puerto.contenedor)||','||(select count(*) from puerto.detalle_mercancia)||','||(select count(*) from puerto.inspeccion_transito)"
for N in 1 2 3; do
  P=$(bash scripts/primario_actual.sh $N) || { echo "=== Fragmento $N: SIN primario vivo ==="; continue; }
  if [ "$P" = "nodo$N" ]; then S=nodo${N}sb; else S=nodo$N; fi
  echo "=== Fragmento $N: primario=$P standby=$S ==="
  docker compose exec -T $P psql -U postgres -d puerto -c "select application_name, state, sync_state, replay_lag, pg_wal_lsn_diff(sent_lsn, replay_lsn) as bytes_pendientes from pg_stat_replication"
  echo -n "Timeline del primario: "; docker compose exec -T $P psql -U postgres -d puerto -Atc "select timeline_id from pg_control_checkpoint()"
  sleep 1
  CP=$(docker compose exec -T $P psql -U postgres -d puerto -Atc "$CONTEOS" | tr -d '\r')
  CS=$(docker compose exec -T $S psql -U postgres -d puerto -Atc "$CONTEOS" 2>/dev/null | tr -d '\r')
  if [ -z "$CS" ]; then echo "Standby $S no responde"
  elif [ "$CP" = "$CS" ]; then echo "Conteos primario = standby ($CP): OK"
  else echo "DIFERENTES -> primario: $CP | standby: $CS"; fi
done
