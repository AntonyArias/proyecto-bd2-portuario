# Plan B (si el esquema de 3 fragmentos con 6 nodos fallara)

Un primario con 2 standby y particionamiento declarativo. El spike del esquema principal funcionó, así que esto es solo documentación.

1. Un único primario (`nodo1`) con todos los datos; `manifiesto_carga` particionada por `LIST (id_terminal_maritima)`.
2. Las tablas hijas particionadas por `RANGE` sobre su ID (nodo N = `id / 10^9`), sin agregar `id_terminal` a las hijas.
3. Dos standby físicos del primario (`nodo2`, `nodo3`), con replicación sincrónica a uno de ellos.
4. Failover: promover un standby con `pg_promote()` y reapuntar a los clientes (lista de hosts con `target_session_attrs=read-write`).
5. Se pierde: el aislamiento de fallos por terminal y la escritura en paralelo en nodos distintos. Se gana: un solo nodo de escritura y sin `postgres_fdw`.
