#!/bin/bash
# Caida forzosa (SIGKILL) del primario actual del fragmento N: matar.sh 2
N=$1; P=$(bash "$(dirname "$0")/primario_actual.sh" $N)
echo "Matando $P a las $(date +%T)"; docker compose kill $P
