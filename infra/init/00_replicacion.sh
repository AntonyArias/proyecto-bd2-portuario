#!/bin/bash
# Solo corre en el PRIMER arranque de un primario (los standbys heredan esto por clonacion).
set -e
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SET password_encryption = 'scram-sha-256'; CREATE ROLE replicador WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}'"

if [ -s /seguridad/pg_hba_seguro.conf ]; then
  cp /seguridad/pg_hba_seguro.conf "$PGDATA/pg_hba.conf"
else
  cat > "$PGDATA/pg_hba.conf" << 'EOF'
local   all             all                                     trust
local   replication     all                                     trust
hostnossl all           all             all                     reject
hostnossl replication   all             all                     reject
hostssl replication     replicador      all                     scram-sha-256
hostssl all             all             all                     scram-sha-256
EOF
fi
chown postgres:postgres "$PGDATA/pg_hba.conf"
chmod 600 "$PGDATA/pg_hba.conf"
