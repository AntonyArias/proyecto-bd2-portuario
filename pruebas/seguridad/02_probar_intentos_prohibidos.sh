#!/bin/bash
# =====================================================================
# PRUEBA DE SEGURIDAD 2: RBAC (Menor Privilegio), Cifrado AES-256,
# Bitácora Inmutable, RLS y Pruebas de Intentos Prohibidos
# Proyecto: Sistema de Logística Portuaria y Aduanera (Rol 3)
# Todas las pruebas se ejecutan sobre conexión TCP + SSL (sslmode=require).
# Uso: bash pruebas/seguridad/02_probar_intentos_prohibidos.sh
# =====================================================================
set -e
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
[ -f infra/.env ] || { echo "ERROR: Falta infra/.env"; exit 1; }
set -a; . infra/.env; set +a

P1="nodo1"
for h in nodo1 nodo1sb; do
  r=$(docker compose -f infra/docker-compose.yml exec -T "$h" psql -U postgres -d puerto -Atc "SELECT pg_is_in_recovery()" 2>/dev/null | tr -d '\r' || true)
  [ "$r" = "f" ] && P1="$h" && break
done

run_tcp() {
  local usr="$1"
  local pwd="$2"
  local sql="$3"
  docker compose -f infra/docker-compose.yml exec -T \
    -e PGPASSWORD="$pwd" -e PGSSLMODE="require" "$P1" \
    psql -h 127.0.0.1 -p 5432 -U "$usr" -d puerto -v ON_ERROR_STOP=1 -c "$sql"
}

expect_denied() {
  local etiqueta="$1"
  local usr="$2"
  local pwd="$3"
  local sql="$4"
  set +e
  local out
  out=$(docker compose -f infra/docker-compose.yml exec -T \
    -e PGPASSWORD="$pwd" -e PGSSLMODE="require" "$P1" \
    psql -h 127.0.0.1 -p 5432 -U "$usr" -d puerto -v ON_ERROR_STOP=1 -c "$sql" 2>&1)
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "FALLO DE SEGURIDAD: [$etiqueta] fue PERMITIDO cuando debía ser DENEGADO!"
    exit 1
  fi
  echo "  [BLOQUEADO OK] $etiqueta -> $(echo "$out" | grep -iE 'ERROR:|permission denied|must be owner' | head -n 1 | tr -d '\r')"
}

echo "====================================================================="
echo " PRUEBA SEGURIDAD 2: RBAC, Cifrado AES-256 e Intentos Prohibidos ($P1)"
echo "====================================================================="

echo ""
echo ">>> [1/4] rol_lectura (auditor_user): lectura permitida, datos *_Enc ilegibles y escrituras bloqueadas"
echo "  Muestra SELECT directo sobre columnas cifradas (ilegible para auditor_user):"
run_tcp auditor_user "$AUDITOR_PASS" \
  'SELECT "CT_CodigoLicencia", left(encode("CT_CedulaEnc", '\''hex'\''), 32) || '\''...'\'' AS cedula_cifrada_hex FROM puerto."AgenteAduanero" ORDER BY 1 LIMIT 3;'

expect_denied "auditor_user INSERT en catalogo Pais" auditor_user "$AUDITOR_PASS" \
  'INSERT INTO puerto."Pais" ("CI_IdPais","CT_CodigoIso","CT_Nombre") VALUES (99,'\''ZZ'\'','\''Intento'\'');'
expect_denied "auditor_user UPDATE en Contenedor" auditor_user "$AUDITOR_PASS" \
  'UPDATE puerto."Contenedor" SET "CI_IdEstadoContenedor" = 6 WHERE "CI_IdContenedor" = 1000000001;'
expect_denied "auditor_user DELETE en InspeccionTransito" auditor_user "$AUDITOR_PASS" \
  'DELETE FROM puerto."InspeccionTransito" WHERE "CI_IdInspeccionTransito" = 1000000001;'
expect_denied "auditor_user CALL sp_despachar_mercancia" auditor_user "$AUDITOR_PASS" \
  'CALL puerto.sp_despachar_mercancia(1000000001, '\''AA-00001'\'', '\''intento auditor'\'', NULL);'
expect_denied "auditor_user invocar puerto.descifrar()" auditor_user "$AUDITOR_PASS" \
  'SELECT puerto.descifrar("CT_CedulaEnc") FROM puerto."AgenteAduanero" LIMIT 1;'
expect_denied "auditor_user consultar VistaAgenteSeguro" auditor_user "$AUDITOR_PASS" \
  'SELECT * FROM puerto."VistaAgenteSeguro" LIMIT 1;'
expect_denied "auditor_user consultar VistaDetalleMercanciaSeguro" auditor_user "$AUDITOR_PASS" \
  'SELECT * FROM puerto."VistaDetalleMercanciaSeguro" LIMIT 1;'
expect_denied "auditor_user leer BitacoraAuditoria" auditor_user "$AUDITOR_PASS" \
  'SELECT * FROM puerto."BitacoraAuditoria" LIMIT 1;'
expect_denied "auditor_user leer llave en seguridad_interna.ConfigCifrado" auditor_user "$AUDITOR_PASS" \
  'SELECT * FROM seguridad_interna."ConfigCifrado";'

echo ""
echo ">>> [2/4] rol_operador (operador_user): opera SPs y bitacora operativa, pero SIN DELETE ni descifrado"
IMO_VAL=$(docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -qAtc \
  'SELECT "CT_NumeroImo" FROM puerto."Buque" ORDER BY "CI_IdBuque" LIMIT 1;' | tr -d '\r')
CONT_DISPONIBLE=$(docker compose -f infra/docker-compose.yml exec -T "$P1" psql -U postgres -d puerto -qAtc \
  'SELECT "CI_IdContenedor" FROM puerto."Contenedor" WHERE "CI_IdEstadoContenedor" IN (2,3,4,6) ORDER BY "CI_IdContenedor" LIMIT 1;' | tr -d '\r')

run_tcp operador_user "$OPERADOR_PASS" \
  "CALL puerto.sp_registrar_inspeccion(1::SMALLINT, $CONT_DISPONIBLE, 2::SMALLINT, 1, 'CONFORME', 'Prueba RBAC operador_user');"
echo "  [PERMITIDO OK] operador_user ejecuto sp_registrar_inspeccion sobre contenedor $CONT_DISPONIBLE."

RLS_OTRA=$(docker compose -f infra/docker-compose.yml exec -T \
  -e PGPASSWORD="$OPERADOR_PASS" -e PGSSLMODE="require" "$P1" \
  psql -h 127.0.0.1 -p 5432 -U operador_user -d puerto -qAtc \
  'SET app.terminal_asignada = '\''2'\''; SELECT count(*) FROM puerto."ManifiestoCarga";' | tr -d '\r')
echo "  [RLS OK] operador_user con app.terminal_asignada='2' en nodo 1 (Moin) ve $RLS_OTRA filas (esperado: 0)."
[ "$RLS_OTRA" = "0" ] || exit 1

expect_denied "operador_user DELETE en Contenedor" operador_user "$OPERADOR_PASS" \
  "DELETE FROM puerto.\"Contenedor\" WHERE \"CI_IdContenedor\" = $CONT_DISPONIBLE;"
expect_denied "operador_user INSERT en catalogo PartidaArancelaria" operador_user "$OPERADOR_PASS" \
  'INSERT INTO puerto."PartidaArancelaria" VALUES (99,'\''999999'\'','\''Ilegal'\'',0);'
expect_denied "operador_user invocar puerto.descifrar()" operador_user "$OPERADOR_PASS" \
  'SELECT puerto.descifrar("CT_ValorArancelarioEnc") FROM puerto."DetalleMercancia" LIMIT 1;'
expect_denied "operador_user consultar VistaAgenteSeguro" operador_user "$OPERADOR_PASS" \
  'SELECT * FROM puerto."VistaAgenteSeguro" LIMIT 1;'
expect_denied "operador_user consultar VistaDetalleMercanciaSeguro" operador_user "$OPERADOR_PASS" \
  'SELECT * FROM puerto."VistaDetalleMercanciaSeguro" LIMIT 1;'
expect_denied "operador_user consultar esquema global (FDW)" operador_user "$OPERADOR_PASS" \
  'SELECT count(*) FROM global."ManifiestoCarga";'
expect_denied "operador_user leer llave en seguridad_interna.ConfigCifrado" operador_user "$OPERADOR_PASS" \
  'SELECT * FROM seguridad_interna."ConfigCifrado";'

echo ""
echo ">>> [3/4] rol_admin (admin_user): accede a vistas descifradas, bitacora y FDW, sin romper inmutabilidad ni ver ConfigCifrado"
echo "  VistaAgenteSeguro (datos sensibles descifrados para admin_user):"
run_tcp admin_user "$ADMIN_PASS" \
  'SELECT "CT_CodigoLicencia", "CT_Nombre", "CT_Apellidos", "CT_Cedula", "CT_Telefono" FROM puerto."VistaAgenteSeguro" ORDER BY "CI_IdAgenteAduanero" LIMIT 3;'

echo "  VistaDetalleMercanciaSeguro (valores arancelarios descifrados para admin_user):"
run_tcp admin_user "$ADMIN_PASS" \
  'SELECT "CT_NumeroIso", "CT_CodigoHs", "CT_Descripcion", "CD_ValorDeclaradoUsd", "CD_ValorArancelarioUsd" FROM puerto."VistaDetalleMercanciaSeguro" ORDER BY "CI_IdDetalleMercancia" LIMIT 3;'

echo "  Consultas globales distribuidas (FDW) autorizadas para admin_user:"
run_tcp admin_user "$ADMIN_PASS" \
  'SELECT "CI_IdTerminalMaritima" AS terminal, count(*) AS manifiestos FROM global."ManifiestoCarga" GROUP BY 1 ORDER BY 1;'

echo "  BitacoraAuditoria (ultimos 3 eventos):"
run_tcp admin_user "$ADMIN_PASS" \
  'SELECT "CI_IdEvento", "CT_TablaAfectada", "CT_Operacion", "CT_UsuarioSesion", "CT_Detalle" FROM puerto."BitacoraAuditoria" ORDER BY "CI_IdEvento" DESC LIMIT 3;'

expect_denied "admin_user DELETE BitacoraAuditoria (inmutable)" admin_user "$ADMIN_PASS" \
  'DELETE FROM puerto."BitacoraAuditoria";'
expect_denied "admin_user leer llave directa en seguridad_interna.ConfigCifrado" admin_user "$ADMIN_PASS" \
  'SELECT * FROM seguridad_interna."ConfigCifrado";'

echo ""
echo ">>> [4/4] Verificacion final en tabla fisica vs vistas (demo comparativa):"
run_tcp auditor_user "$AUDITOR_PASS" \
  'SELECT "CI_IdDetalleMercancia", encode("CT_ValorDeclaradoEnc", '\''hex'\'') AS valor_en_disco_ilegible FROM puerto."DetalleMercancia" ORDER BY 1 LIMIT 2;'

echo "=== PRUEBA SEGURIDAD 2 (RBAC + CIFRADO + RLS + AUDITORIA) SUPERADA ==="
