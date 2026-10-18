#!/bin/bash
# Solo corre en el PRIMER arranque de un primario (los standbys heredan esto por clonacion).
set -e
psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "CREATE ROLE replicador WITH REPLICATION LOGIN PASSWORD '${REPL_PASS}'"
echo "host replication replicador all scram-sha-256" >> "$PGDATA/pg_hba.conf"
