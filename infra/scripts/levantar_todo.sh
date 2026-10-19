#!/bin/bash
# Levanta los 6 nodos, espera a que esten healthy, carga datos, vistas globales y sincrona.
# Solo sobre un cluster VACIO (para empezar de cero usa reiniciar_limpio.sh).
set -e; cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Falta .env (copia .env.example a .env)"; exit 1; }
docker compose up -d
echo "Esperando a que los 6 nodos esten healthy..."
n=0
for i in $(seq 1 60); do
  n=$(docker compose ps | grep -c "(healthy)" || true)
  [ "$n" -eq 6 ] && break
  sleep 3
done
[ "$n" -eq 6 ] || { echo "Solo $n/6 healthy; revisa: docker compose ps"; exit 1; }
bash scripts/cargar.sh
bash scripts/fdw.sh
for N in 1 2 3; do bash scripts/sincrona.sh $N on; done
bash scripts/verificar_replicas.sh
