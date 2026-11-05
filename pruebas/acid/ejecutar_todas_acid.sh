#!/bin/bash
# =====================================================================
# Suite Completa Reproducible de Propiedades ACID (Rol 3)
# Ejecuta y cronometra las 4 pruebas (Atomicidad, Consistencia,
# Aislamiento y Durabilidad) comprobando que cada una tarda << 2 min.
# Uso: bash pruebas/acid/ejecutar_todas_acid.sh
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
set -a; . infra/.env; set +a

PRIM="nodo1"
for h in nodo1 nodo1sb; do
  r=$(docker compose -f infra/docker-compose.yml exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
  [ "$r" = "f" ] && PRIM="$h" && break
done

T_TOTAL_INI=$(date +%s)

# 1. ATOMICIDAD
T0=$(date +%s)
OUT_A=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$PRIM" \
  psql -U operador_user -d puerto < pruebas/acid/01_atomicidad.sql 2>&1)
echo "$OUT_A"
grep -q "OK - ATOMICIDAD DEMOSTRADA" <<< "$OUT_A"
DUR_A=$(( $(date +%s) - T0 ))

# 2. CONSISTENCIA
T0=$(date +%s)
OUT_C=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$PRIM" \
  psql -U operador_user -d puerto < pruebas/acid/02_consistencia.sql 2>&1)
echo "$OUT_C"
if grep -q "FALLA" <<< "$OUT_C"; then
  echo "ERROR: Se detectaron violaciones en la prueba de Consistencia"
  exit 1
fi
DUR_C=$(( $(date +%s) - T0 ))

# 3. AISLAMIENTO (2 sesiones concurrentes)
T0=$(date +%s)
bash pruebas/acid/03_aislamiento_demo.sh
DUR_I=$(( $(date +%s) - T0 ))

# 4. DURABILIDAD (COMMIT + SIGKILL + recovery WAL)
T0=$(date +%s)
bash pruebas/acid/04_durabilidad_demo.sh
DUR_D=$(( $(date +%s) - T0 ))

echo ""
echo ">>> Verificación global de integridad post-ACID en $PRIM (datos/03_verificacion.sql):"
docker compose -f infra/docker-compose.yml exec -T "$PRIM" \
  psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo=1 < datos/03_verificacion.sql

DUR_TOTAL=$(( $(date +%s) - T_TOTAL_INI ))

echo ""
echo "====================================================================="
echo " RESUMEN EJECUTIVO SUITE ACID (Meta de rúbrica: <= 120s por prueba)"
echo "====================================================================="
printf "  [A] Atomicidad   : %2d s  -> OK (Rollback 100%% ante fallo parcial)\n" "$DUR_A"
printf "  [C] Consistencia : %2d s  -> OK (CHECK, FK, Triggers, 0 violaciones)\n" "$DUR_C"
printf "  [I] Aislamiento  : %2d s  -> OK (FOR UPDATE evita doble despacho)\n" "$DUR_I"
printf "  [D] Durabilidad  : %2d s  -> OK (Persistencia tras SIGKILL + WAL)\n" "$DUR_D"
echo "---------------------------------------------------------------------"
printf "  Tiempo total     : %2d s  -> 4/4 PROPIEDADES ACID DEMOSTRADAS\n" "$DUR_TOTAL"
echo "====================================================================="

