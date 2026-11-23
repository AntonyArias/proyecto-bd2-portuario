#!/bin/bash
# =====================================================================
# Suite Completa de Seguridad (SSL/TLS + SCRAM-SHA-256 + RBAC + Cifrado)
# Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
# Uso: bash pruebas/seguridad/ejecutar_todas_seguridad.sh
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

bash pruebas/seguridad/01_probar_ssl_y_scram.sh
echo ""
bash pruebas/seguridad/02_probar_intentos_prohibidos.sh
echo ""
echo "=== SUITE COMPLETA DE SEGURIDAD SUPERADA CON EXITO ==="
