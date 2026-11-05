#!/bin/bash
# =====================================================================
# Aplica rutinas transaccionales, triggers y seguridad (Rol 3) en los
# 3 primarios activos del cluster (los 3 standbys lo reciben por WAL).
# Uso: bash sql/aplicar_rol3.sh
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra"

[ -f "$INFRA_DIR/.env" ] || {
  echo "ERROR: Falta $INFRA_DIR/.env (copia infra/.env.example a infra/.env)"
  exit 1
}

set -a
. "$INFRA_DIR/.env"
set +a

for VAR in ENC_KEY AUDITOR_PASS OPERADOR_PASS ADMIN_PASS; do
  if [ -z "${!VAR}" ]; then
    echo "ERROR: Falta definir $VAR en infra/.env"
    exit 1
  fi
done

cd "$INFRA_DIR"

primario_de() {
  for h in "nodo$1" "nodo${1}sb"; do
    r=$(docker compose exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
    if [ "$r" = "f" ]; then
      echo "$h"
      return 0
    fi
  done
  return 1
}

for N in 1 2 3; do
  P=$(primario_de "$N") || { echo "ERROR: Fragmento $N sin primario activo"; exit 1; }
  echo "==================================================="
  echo " Aplicando Rol 3 en fragmento $N (primario: $P)"
  echo "==================================================="

  docker compose exec -T "$P" psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo="$N" \
    < "$ROOT_DIR/sql/04_rutinas/01_sp_ingresar_manifiesto.sql"

  docker compose exec -T "$P" psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo="$N" \
    < "$ROOT_DIR/sql/04_rutinas/02_sp_despachar_mercancia.sql"

  docker compose exec -T "$P" psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo="$N" \
    < "$ROOT_DIR/sql/04_rutinas/03_triggers_inventario_y_pesos.sql"

  docker compose exec -T "$P" psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo="$N" \
    -v enc_key="$ENC_KEY" \
    -v auditor_pass="$AUDITOR_PASS" \
    -v operador_pass="$OPERADOR_PASS" \
    -v admin_pass="$ADMIN_PASS" \
    < "$ROOT_DIR/sql/05_seguridad/01_roles_y_seguridad.sql"
done

echo "==================================================="
echo " Verificando integridad y replicacion en los 6 nodos"
echo "==================================================="
CONTEOS_SQL="SELECT (SELECT count(*) FROM puerto.manifiesto_carga)||','||(SELECT count(*) FROM puerto.contenedor)||','||(SELECT count(*) FROM puerto.detalle_mercancia)||','||(SELECT count(*) FROM puerto.inspeccion_transito)"
for N in 1 2 3; do
  P=$(primario_de "$N")
  if [ "$P" = "nodo$N" ]; then S="nodo${N}sb"; else S="nodo$N"; fi
  echo "--- Verificacion fragmento $N (primario=$P, standby=$S) ---"
  docker compose exec -T "$P" psql -U postgres -d puerto -v ON_ERROR_STOP=1 -v nodo="$N" \
    < "$ROOT_DIR/datos/03_verificacion.sql"
  sleep 1
  CP=$(docker compose exec -T "$P" psql -U postgres -d puerto -Atc "$CONTEOS_SQL" | tr -d '\r')
  CS=$(docker compose exec -T "$S" psql -U postgres -d puerto -Atc "$CONTEOS_SQL" | tr -d '\r')
  if [ "$CP" = "$CS" ]; then
    echo "Replicacion OK ($P == $S -> $CP)"
  else
    echo "ERROR de conteos entre primario ($CP) y standby ($CS)"
    exit 1
  fi
done

echo "=== Rol 3 aplicado y verificado con exito en los 3 fragmentos ==="
