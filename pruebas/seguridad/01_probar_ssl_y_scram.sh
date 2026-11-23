#!/bin/bash
# =====================================================================
# PRUEBA DE SEGURIDAD 1: SSL/TLS, pg_hba.conf (hostssl) y SCRAM-SHA-256
# Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
# Uso: bash pruebas/seguridad/01_probar_ssl_y_scram.sh
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
[ -f infra/.env ] || { echo "ERROR: Falta infra/.env"; exit 1; }
set -a; . infra/.env; set +a

primario_de() {
  for h in "nodo$1" "nodo${1}sb"; do
    r=$(docker compose -f infra/docker-compose.yml exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
    [ "$r" = "f" ] && echo "$h" && return 0
  done
  return 1
}

echo "====================================================================="
echo " PRUEBA SEGURIDAD 1: SSL/TLS (hostssl) y SCRAM-SHA-256 en los 6 nodos"
echo "====================================================================="

echo ""
echo ">>> [1/5] Parametros SSL y password_encryption en los 6 contenedores:"
for H in nodo1 nodo1sb nodo2 nodo2sb nodo3 nodo3sb; do
  INFO=$(docker compose -f infra/docker-compose.yml exec -T "$H" psql -U postgres -d puerto -Atc "
    SELECT '$H | ssl=' || current_setting('ssl')
        || ' | min_tls=' || current_setting('ssl_min_protocol_version')
        || ' | pwd_enc=' || current_setting('password_encryption');" | tr -d '\r')
  echo "  $INFO"
  grep -q "ssl=on" <<< "$INFO"
  grep -q "pwd_enc=scram-sha-256" <<< "$INFO"
done

P1=$(primario_de 1)
echo ""
echo ">>> [2/5] Reglas activas de pg_hba.conf (desde pg_hba_file_rules en $P1):"
docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -c "
SELECT line_number, type, database, user_name, address, auth_method, error
  FROM pg_hba_file_rules
 ORDER BY line_number;"

echo ""
echo ">>> [3/5] Prueba negativa: conexion TCP SIN SSL (sslmode=disable) debe ser RECHAZADA:"
set +e
ERR_NOSSL=$(docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" -e PGSSLMODE="disable" "$P1" \
  psql -h 127.0.0.1 -p 5432 -U operador_user -d puerto -c "SELECT 1;" 2>&1)
RC_NOSSL=$?
set -e
echo "  Codigo salida=$RC_NOSSL | Respuesta: $(echo "$ERR_NOSSL" | tr -d '\r' | tr '\n' ' ')"
if [ "$RC_NOSSL" -eq 0 ]; then
  echo "FALLO: Se permitio una conexion TCP sin SSL!"
  exit 1
fi
echo "  OK: Conexion TCP sin SSL rechazada correctamente por pg_hba.conf (hostnossl ... reject)."

echo ""
echo ">>> [4/5] Prueba positiva: conexion TCP CON SSL obligatorio (sslmode=require) y verificacion en pg_stat_ssl:"
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" -e PGSSLMODE="require" "$P1" \
  psql -h 127.0.0.1 -p 5432 -U operador_user -d puerto -c "
SELECT s.pid,
       a.usename,
       a.client_addr,
       s.ssl,
       s.version AS tls_version,
       s.cipher
  FROM pg_stat_ssl s
  JOIN pg_stat_activity a USING (pid)
 WHERE s.pid = pg_backend_pid();"

echo ""
echo ">>> Verificando conexiones internas con SSL (replicacion WAL y postgres_fdw):"
docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -c "
SELECT count(*) AS conexiones_ssl_activas,
       string_agg(DISTINCT s.version, ', ') AS versiones_tls
  FROM pg_stat_ssl s
 WHERE s.ssl = true;"

echo ""
echo ">>> [5/5] Verificando almacenamiento de hashes SCRAM-SHA-256 en pg_authid (ninguno en texto plano o MD5):"
docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -c "
SELECT rolname,
       split_part(rolpassword, '$', 1) AS algoritmo_hash,
       left(rolpassword, 26) || '...' AS prefijo_hash
  FROM pg_authid
 WHERE rolname IN ('auditor_user','operador_user','admin_user','replicador','postgres')
 ORDER BY rolname;"

NON_SCRAM=$(docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -Atc "
SELECT count(*)
  FROM pg_authid
 WHERE rolname IN ('auditor_user','operador_user','admin_user','replicador')
   AND (rolpassword IS NULL OR rolpassword NOT LIKE 'SCRAM-SHA-256$%');" | tr -d '\r')
[ "$NON_SCRAM" = "0" ] || { echo "FALLO: Hay $NON_SCRAM roles sin SCRAM-SHA-256!"; exit 1; }

echo "=== PRUEBA SEGURIDAD 1 (SSL/TLS + hostssl + SCRAM-SHA-256) SUPERADA ==="
