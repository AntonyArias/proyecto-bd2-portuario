#!/bin/bash
# cargar.sh | Ejecuta DDL + DML + verificacion en un nodo (1|2|3) o en 'todos'.
# Uso:
#   ./sql/cargar.sh 1                 # carga solo nodo 1 (Moin)
#   ./sql/cargar.sh todos --reset     # borra esquema puerto y recarga desde cero los 3 nodos
#   N_MAN=500 ./sql/cargar.sh 1 --reset
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OBJ="${1:?Uso: ./sql/cargar.sh <1|2|3|todos> [--reset]}"
RESET="${2:-}"

if [ -f "$DIR/.env" ]; then
  set -a; . "$DIR/.env"; set +a
  export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
elif [ -f "$DIR/infra/.env" ]; then
  set -a; . "$DIR/infra/.env"; set +a
  export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
fi

PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-puerto}"
PGHOST="${PGHOST:-localhost}"

cargar_nodo() {
  local N=$1
  local PORT=$((5440 + N))
  echo "=========================================="
  echo ">>> Cargando Nodo $N (puerto $PORT)..."
  echo "=========================================="
  local PSQL="psql -h $PGHOST -p $PORT -U $PGUSER -d $PGDATABASE -v ON_ERROR_STOP=1"

  if [ "$RESET" = "--reset" ]; then
    echo "  -> Reiniciando esquema puerto (--reset)..."
    $PSQL -q -c "DROP SCHEMA IF EXISTS puerto CASCADE;"
  fi

  echo "  -> Aplicando DDL (00..04)..."
  $PSQL -q -f "$DIR/sql/01_ddl/00_esquema.sql"
  $PSQL -q -f "$DIR/sql/01_ddl/01_catalogos.sql"
  $PSQL -q -f "$DIR/sql/01_ddl/02_entidades_comunes.sql"
  $PSQL -q -v nodo=$N -f "$DIR/sql/01_ddl/03_fragmento.sql"
  $PSQL -q -f "$DIR/sql/01_ddl/04_stub_cifrado.sql"

  echo "  -> Aplicando DML masivo (01..03)..."
  $PSQL -q -f "$DIR/sql/02_dml/01_catalogos.sql"
  $PSQL -q -f "$DIR/sql/02_dml/02_entidades_comunes.sql"
  if [ -n "${N_MAN:-}" ]; then
    $PSQL -q -v nodo=$N -v n_man=$N_MAN -f "$DIR/sql/02_dml/03_fragmento.sql"
  else
    $PSQL -q -v nodo=$N -f "$DIR/sql/02_dml/03_fragmento.sql"
  fi

  echo "  -> Ejecutando verificacion de integridad..."
  $PSQL -v nodo=$N -f "$DIR/pruebas/verificar_datos.sql"
}

if [ "$OBJ" = "todos" ]; then
  for n in 1 2 3; do cargar_nodo $n; done
elif [[ "$OBJ" =~ ^[123]$ ]]; then
  cargar_nodo "$OBJ"
else
  echo "ERROR: indique 1, 2, 3 o todos"
  exit 1
fi
