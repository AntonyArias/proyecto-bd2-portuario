# Guía de failover (caída de un primario y recuperación)

Cada fragmento (terminal) tiene un primario y un standby con replicación física en streaming y sincrónica
(`synchronous_standby_names = 'FIRST 1 (walreceiver)'`). Los nombres `nodoN` / `nodoNsb` **no fijan el rol**: tras un failover
el standby promovido es el primario. Los scripts detectan el rol real con `pg_is_in_recovery()`.

## Procedimiento con scripts (desde `infra/`, en Git Bash)

1. Estado inicial: `bash scripts/verificar_cluster.sh` (todos `streaming | sync` y conteos iguales).
2. Caída: `bash scripts/matar.sh N` (SIGKILL del primario del fragmento N).
3. Promoción: `bash scripts/failover.sh N` (promueve el standby vivo y apaga la sincrónica: sin standby, el primario bloquearía las escrituras).
4. Reintegro: `bash scripts/rejoin.sh N` (reconstruye el nodo caído como standby del nuevo primario, espera `streaming` y reactiva la sincrónica).
5. Verificación: `bash scripts/verificar_cluster.sh`.

Ensayo automatizado con carga concurrente: `bash scripts/ensayo_caida.sh N` (resultados en `ensayos/`).

## Procedimiento en pgAdmin
- Caída: Docker Desktop → botón de parada del contenedor (o `matar.sh N` para un corte abrupto).
- Promoción: en el Query Tool del standby, `select pg_promote(wait_seconds => 30);` y luego `select pg_is_in_recovery();` (debe dar `false`).
- Con sincrónica activa, en el nuevo primario: `alter system set synchronous_standby_names = ''; select pg_reload_conf();`.
- Observación: pestaña Dashboard del server (transacciones por segundo). Estado: `pruebas/verificar_cluster.sql`.

## Por qué el nodo caído no vuelve solo
Al promover, el standby abre una nueva *timeline*. El primario viejo conserva datos de la timeline anterior y no puede seguir al nuevo
primario tal cual: hay que rebobinarlo (`pg_rewind`, posible porque `wal_log_hints=on`) o reconstruirlo desde el primario actual (`pg_basebackup`,
lo que hace `rejoin.sh`). Comprobación: `select timeline_id from pg_control_checkpoint();` pasa de 1 a 2.

## Resultados de los ensayos (6 hilos, ~1 200 inserts/s, 45 s, caída a los ~10 s)
| Fragmento | Confirmadas al cliente | Perdidas | En duda | Ventana sin escritura |
|---|---|---|---|---|
| 1 | 53 687 | 0 | 3 | 12,1 s |
| 2 | 55 944 | 0 | 1 | 12,1 s |
| 3 | 54 821 | 0 | 1 | 12,2 s |

La ventana incluye el tiempo del script (varios `docker compose exec`); `pg_promote` en sí tarda 1 a 2 s. La conmutación es manual (sin gestor automático).

## Preguntas difíciles
- **¿Qué pasa con una transacción en vuelo cuando cae el nodo?** Si no llegó al `COMMIT`, se pierde y el cliente recibe error y reintenta. Si el `COMMIT` ocurrió pero la conexión se cortó antes de avisar, el cliente no sabe si se aplicó ("en duda"); debe verificar o reintentar de forma idempotente.
- **¿Por qué no hay transacciones entre terminales?** Cada terminal se escribe solo en su primario y todas las FK del fragmento se resuelven localmente (catálogos replicados), así no hace falta commit en dos fases y se conserva ACID local.
- **¿Qué se pierde con replicación asíncrona?** Las últimas transacciones confirmadas que el standby aún no recibió. La sincrónica lo evita a costa de latencia y de bloquear escrituras si el standby cae.
- **¿Qué pasa si cae el standby con sincrónica activa?** El primario deja de confirmar escrituras hasta que vuelva el standby o se apague la sincrónica.
- **¿Las consultas globales sobreviven a la caída?** Las lecturas sí: cada servidor foráneo lista `nodoN,nodoNsb` y usa el que responda.
