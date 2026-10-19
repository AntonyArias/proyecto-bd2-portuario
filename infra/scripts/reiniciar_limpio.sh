#!/bin/bash
# BORRA todos los datos y reconstruye el cluster completo desde cero.
set -e; cd "$(dirname "$0")/.."
docker compose down -v
bash scripts/levantar_todo.sh
