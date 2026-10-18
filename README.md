# Proyecto BD2 - Sistema portuario distribuido

- `datos/`  -> Rol A (DDL, DML, verificacion, diagrama ER). NO editar aqui; pedir cambios a Rol A.
- `infra/`  -> Rol B (docker-compose, scripts de carga, replicacion, FDW, failover, estres).
- `transacciones/` -> Rol C (crear al integrar).

Orden: ver infra/scripts. Primera vez:  cd infra && docker compose up -d && bash scripts/cargar.sh
