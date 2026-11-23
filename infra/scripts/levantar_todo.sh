#!/bin/bash
# Levanta los 6 nodos con SSL/TLS, espera healthy, carga datos, vistas FDW,
# replicacion sincrona y rutinas/seguridad del Rol 3 (si estan las variables en .env).
# Solo sobre un cluster VACIO (para empezar de cero usa reiniciar_limpio.sh).
set -e; export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Falta .env (copia .env.example a .env)"; exit 1; }
set -a; . ./.env; set +a

if [ -f ../sql/05_seguridad/generar_ssl.sh ] && { [ ! -s ssl/server.key ] || [ ! -s ssl/server.crt ]; }; then
  bash ../sql/05_seguridad/generar_ssl.sh "$(pwd)/ssl"
fi

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

if [ -n "${ENC_KEY:-}" ] && [ -f ../sql/aplicar_rol3.sh ]; then
  bash ../sql/aplicar_rol3.sh
fi

bash scripts/verificar_replicas.sh
