#!/bin/bash
# =====================================================================
# Demostración automatizada de DURABILIDAD (ACID - D)
# 1. Confirma COMMIT de un manifiesto nuevo en el nodo primario.
# 2. Provoca apagado eléctrico abrupto (SIGKILL) del contenedor primario.
# 3. Comprueba RPO=0 leyendo el registro confirmado en el standby mientras
#    el primario sigue apagado.
# 4. Arranca de nuevo el primario, muestra la recuperación automática WAL
#    (crash recovery) y comprueba que los datos y su cifrado siguen intactos.
# Duración estimada: ~10 segundos.
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
set -a; . infra/.env; set +a

PRIM="nodo1"
STBY="nodo1sb"
for h in nodo1 nodo1sb; do
  r=$(docker compose -f infra/docker-compose.yml exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
  if [ "$r" = "f" ]; then
    PRIM="$h"
    [ "$PRIM" = "nodo1" ] && STBY="nodo1sb" || STBY="nodo1"
    break
  fi
done

echo "====================================================================="
echo " DEMO DURABILIDAD: Primario=$PRIM | Standby=$STBY"
echo "====================================================================="

# 1. Ejecutar transacción con COMMIT como operador_use
OUT_PASO1=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$PRIM" \
  psql -U operador_user -d puerto < pruebas/acid/04_durabilidad_paso1_commit.sql)
echo "$OUT_PASO1"

NUM_MAN=$(echo "$OUT_PASO1" | grep -oE 'MAN-T1-D[0-9]+' | head -n 1 | tr -d '\r')
[ -n "$NUM_MAN" ] || { echo "ERROR: No se pudo extraer el número de manifiesto confirmado"; exit 1; }

# 2. Apagado forzoso inmediato (SIGKILL = corte abrupto de energía, sin checkpoint limpio)
echo ""
echo ">>> [CRASH] Ejecutando apagado forzoso inmediato (SIGKILL) sobre $PRIM..."
docker compose -f infra/docker-compose.yml kill -s SIGKILL "$PRIM"
docker compose -f infra/docker-compose.yml ps "$PRIM"

# 3. Mientras el primario está MUERTO, comprobar en el standby (RPO = 0)
echo ""
echo ">>> [STANDBY VIVO] Consultando $STBY mientras $PRIM está apagado (prueba RPO=0):"
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$AUDITOR_PASS" "$STBY" \
  psql -U auditor_user -d puerto -v num_man_dur="$NUM_MAN" \
  < pruebas/acid/04_durabilidad_paso2_verificar.sql

# 4. Levantar nuevamente el primario y esperar su recuperación por WAL (ARIES / redo)
echo ""
echo ">>> [RECOVERY] Arrancando de nuevo $PRIM para recuperación automática desde pg_wal..."
docker compose -f infra/docker-compose.yml start "$PRIM"

for i in $(seq 1 30); do
  READY=$(docker compose -f infra/docker-compose.yml exec -T "$PRIM" pg_isready -U postgres -d puerto 2>/dev/null | grep -c "accepting connections" || true)
  [ "$READY" -ge 1 ] && break
  sleep 1
done

echo ""
echo ">>> Extracto del log de recuperación WAL de PostgreSQL en $PRIM:"
docker compose -f infra/docker-compose.yml logs --tail=15 "$PRIM" | grep -iE "(interrupted|redo|recovery|ready to accept)" || true

# 5. Verificar en el primario recuperado tanto el registro como el descifrado de sus valores
echo ""
echo ">>> [PRIMARIO RECUPERADO] Verificando integridad y descifrado post-crash en $PRIM:"
OUT_PASO2=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" "$PRIM" \
  psql -U operador_user -d puerto -v num_man_dur="$NUM_MAN" \
  < pruebas/acid/04_durabilidad_paso2_verificar.sql)
echo "$OUT_PASO2"

docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$ADMIN_PASS" "$PRIM" \
  psql -U admin_user -d puerto -c "
SELECT m.numero_manifiesto, v.numero_iso, v.descripcion, v.valor_declarado_usd, v.valor_arancelario_usd
  FROM puerto.vista_detalle_mercancia_seguro v
  JOIN puerto.contenedor c ON c.id_contenedor = v.id_contenedor
  JOIN puerto.manifiesto_carga m ON m.id_manifiesto_carga = c.id_manifiesto_carga
 WHERE m.numero_manifiesto = '$NUM_MAN';"

grep -q "OK - DURABILIDAD DEMOSTRADA" <<< "$OUT_PASO2"
echo "=== PRUEBA 4 (DURABILIDAD) SUPERADA CON ÉXITO ==="
