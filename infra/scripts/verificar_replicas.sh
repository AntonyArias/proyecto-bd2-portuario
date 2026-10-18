#!/bin/bash
# Estado de replicacion + 03_verificacion.sql corrido contra cada standby (solo lectura).
for N in 1 2 3; do
  echo "=== nodo $N: pg_stat_replication ==="
  docker compose exec -T nodo$N psql -U postgres -c "select application_name,state,sync_state,replay_lag from pg_stat_replication"
  echo "=== standby $N: verificacion ==="
  docker compose exec -T nodo${N}sb psql -U postgres -d puerto -v nodo=$N -f /datos/03_verificacion.sql | tee "verif_standby$N.txt"
done
