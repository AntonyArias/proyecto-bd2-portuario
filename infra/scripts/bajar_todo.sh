#!/bin/bash
# Apaga los 6 contenedores SIN borrar datos.
cd "$(dirname "$0")/.." && docker compose down
