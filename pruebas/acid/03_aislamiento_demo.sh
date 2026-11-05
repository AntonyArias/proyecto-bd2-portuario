#!/bin/bash
# =====================================================================
# Demostración automatizada de AISLAMIENTO con 2 sesiones psql concurrentes
# Lanza Sesión 1 en segundo plano, muestra en vivo en pg_stat_activity que
# Sesión 2 está esperando el candado de fila (Lock / tuple), y comprueba
# que solo 1 despacho se confirma. Duración: ~7 segundos.
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
set -a; . infra/.env; set +a

# Detectar primario actual del fragmento 1
NODO="nodo1"
for h in nodo1 nodo1sb; do
  r=$(docker compose -f infra/docker-compose.yml exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
  [ "$r" = "f" ] && NODO="$h" && break
done

ID_CONT=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$NODO" \
  psql -U operador_user -d puerto -qAtc \
  "SELECT id_contenedor FROM puerto.contenedor WHERE id_estado_contenedor IN (2,3,4,6) ORDER BY id_contenedor LIMIT 1;" | tr -d '\r')

echo "====================================================================="
echo " DEMO AISLAMIENTO: 2 sesiones simultáneas sobre contenedor $ID_CONT en $NODO"
echo "====================================================================="

LOG_S1=$(mktemp)
LOG_S2=$(mktemp)
trap 'rm -f "$LOG_S1" "$LOG_S2"' EXIT

# 1. Lanzar Sesión 1 en segundo plano (retiene FOR UPDATE por 5 segundos)
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$NODO" \
  psql -U operador_user -d puerto -v id_cont="$ID_CONT" -v espera_seg=5 \
  < pruebas/acid/03_aislamiento_sesion1.sql > "$LOG_S1" 2>&1 &
PID_S1=$!

sleep 1.2

# 2. Lanzar Sesión 2 en paralelo apuntando al MISMO contenedo
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$NODO" \
  psql -U operador_user -d puerto -v id_cont="$ID_CONT" \
  < pruebas/acid/03_aislamiento_sesion2.sql > "$LOG_S2" 2>&1 &
PID_S2=$!

sleep 1.5

echo ""
echo ">>> Evidencia EN VIVO desde pg_stat_activity (mientras ambas sesiones corren):"
docker compose -f infra/docker-compose.yml exec -T "$NODO" psql -U postgres -d puerto -c "
SELECT pid,
       usename,
       state,
       wait_event_type,
       wait_event,
       left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS consulta_actual
  FROM pg_stat_activity
 WHERE datname = 'puerto'
   AND usename = 'operador_user'
 ORDER BY query_start;"

wait "$PID_S1"
wait "$PID_S2"

echo ""
echo ">>> Salida de SESIÓN 1:"
cat "$LOG_S1"

echo ""
echo ">>> Salida de SESIÓN 2:"
cat "$LOG_S2"

grep -q "OK - AISLAMIENTO DEMOSTRADO" "$LOG_S2"
echo ""
echo "=== PRUEBA 3 (AISLAMIENTO) SUPERADA CON ÉXITO ==="
