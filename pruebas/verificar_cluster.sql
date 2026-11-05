-- Para pgAdmin (Query Tool). Correr cada bloque en el server indicado.

-- A) En un PRIMARIO: estado de la replicacion
select application_name, state, sync_state, replay_lag,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) as bytes_pendientes
from pg_stat_replication;
select pg_is_in_recovery() as es_standby, (select timeline_id from pg_control_checkpoint()) as timeline;
show synchronous_standby_names;

-- B) En un STANDBY: de donde recibe y cuanto se atrasa
select status, sender_host, received_tli from pg_stat_wal_receiver;
select pg_is_in_recovery() as es_standby,
       pg_last_wal_replay_lsn() as lsn_reproducido,
       now() - pg_last_xact_replay_timestamp() as retardo;

-- C) En AMBOS (primario y su standby): los conteos deben ser iguales
select (select count(*) from puerto.manifiesto_carga) as manifiestos,
       (select count(*) from puerto.contenedor) as contenedores,
       (select count(*) from puerto.detalle_mercancia) as detalles,
       (select count(*) from puerto.inspeccion_transito) as inspecciones;
