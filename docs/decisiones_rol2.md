# Decisiones del Rol 2 (para pegar en el registro de la sección 8)

| Fecha | Decisión | Alternativas descartadas | Justificación | Quién |
|---|---|---|---|---|
| 18 oct | Consultas globales con vistas `UNION ALL` sobre tablas foráneas (`postgres_fdw`) | Tabla particionada con particiones foráneas por `id_terminal` | Mantiene 3FN pura (no repite `id_terminal` en las hijas). Mejora posible sin tocar el modelo: particionar por rango de ID (nodo N = `id / 10^9`) | Rol 2 |
| 18 oct | Failover manual con scripts | Patroni / gestor automático | Exige un almacén de consenso (etcd) y más RAM; para una laptop y una demo, el script es explicable y suficiente | Rol 2 |
| 18 oct | Roles no fijos: `nodoN` y `nodoNsb` pueden ser primario o standby | Roles fijos por nombre | Tras un failover se invierten; los scripts detectan el rol con `pg_is_in_recovery()` | Rol 2 |
| 18 oct | Replicación sincrónica `FIRST 1 (walreceiver)`, activada tras la carga y apagada al promover | Asíncrona | RPO 0 (ensayos: 0 transacciones perdidas); si no se apaga tras promover, el primario sin standby bloquea escrituras | Rol 2 |
| 18 oct | Reintegro del nodo caído por reconstrucción (`pg_basebackup`) | `pg_rewind` | Más simple y robusto; `wal_log_hints=on` deja abierta la opción de `pg_rewind` | Rol 2 |
| 18 oct | Claves en `infra/.env` (ignorado por Git) + `.env.example` | Claves escritas en el compose | Regla de secretos de la sección 1 | Rol 2 |
| 18 oct | Nombres `nodoNsb` (no `nodoNb`); carpetas `infra/` y `datos/` (no `docker/` y `sql/`) | Los nombres de la sección 1 | Se implementó así; pendiente de alinear con el equipo o actualizar la sección 1 | Rol 2 |
| 23 oct | Servidores foráneos con `host 'nodoN,nodoNsb'` y `target_session_attrs 'any'` | Un host fijo por nodo | Las vistas globales siguen leyendo si cae el primario de un fragmento | Rol 2 |
