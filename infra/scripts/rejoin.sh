#!/bin/bash
# Reintegra el nodo caido nodoN como STANDBY del nodoNsb ya promovido: rejoin.sh 2
# Re-clona con pg_basebackup (pg_rewind tambien funciona porque wal_log_hints=on ya esta activo).
N=$1
docker compose rm -sf nodo$N
docker volume rm portuaria_nodo${N}_data
env "N${N}_MODO=standby" "N${N}_PEER=nodo${N}sb" docker compose up -d nodo$N
