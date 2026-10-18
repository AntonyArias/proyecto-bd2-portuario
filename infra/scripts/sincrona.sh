#!/bin/bash
# Replicacion sincrona (RPO 0) del fragmento N: sincrona.sh 2 on|off
# OJO: con 'on' y sin standby conectado, el primario BLOQUEA las escrituras. Tras un failover usar 'off' hasta reintegrar.
N=$1; MODE=$2; P=$(bash "$(dirname "$0")/primario_actual.sh" $N)
if [ "$MODE" = "on" ]; then V="'FIRST 1 (walreceiver)'"; else V="''"; fi
docker compose exec -T $P psql -U postgres -c "ALTER SYSTEM SET synchronous_standby_names = $V" -c "select pg_reload_conf()"
sleep 1
docker compose exec -T $P psql -U postgres -Atc "select state, sync_state from pg_stat_replication"
