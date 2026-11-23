# Pruebas de Seguridad, Cifrado y SSL/TLS (`pruebas/seguridad/`)

Suite automatizada para demostrar en vivo el cumplimiento del 15% de **Seguridad de la Información** en la defensa.

## Cómo ejecutar todas las pruebas de seguridad

Desde Git Bash en la raíz del repositorio (con los 6 nodos arriba):

```bash
bash pruebas/seguridad/ejecutar_todas_seguridad.sh
```

Para guardar la salida como evidencia lista para el informe o capturas:

```bash
bash pruebas/seguridad/ejecutar_todas_seguridad.sh | tee pruebas/seguridad/evidencia_seguridad.log
```

## Qué demuestra cada script

1. **[01_probar_ssl_y_scram.sh](01_probar_ssl_y_scram.sh)**
   - Comprueba `ssl = on`, `ssl_min_protocol_version = TLSv1.2` y `password_encryption = scram-sha-256` en los 6 contenedores (`nodo1..3`, `nodo1sb..3sb`).
   - Imprime las reglas activas de `pg_hba_file_rules` (`hostnossl ... reject` y `hostssl ... scram-sha-256`).
   - Verifica que una conexión TCP con `PGSSLMODE=disable` es **rechazada**.
   - Verifica que una conexión TCP con `PGSSLMODE=require` es **aceptada** y muestra en `pg_stat_ssl` la sesión cifrada con TLSv1.3/TLSv1.2, además de las conexiones de replicación y FDW sobre SSL.
   - Comprueba en `pg_authid` que todas las cuentas operativas usan hashes `SCRAM-SHA-256$`.

2. **[02_probar_intentos_prohibidos.sh](02_probar_intentos_prohibidos.sh)**
   - **`auditor_user` (`rol_lectura`)**: consulta datos cifrados viéndolos en hexadecimal ilegible y recibe `permission denied` al intentar escribir, ejecutar procedimientos, invocar `puerto.descifrar()`, leer vistas seguras, leer bitácora o leer `ConfigCifrado`.
   - **`operador_user` (`rol_operador`)**: ejecuta `sp_registrar_inspeccion`, demuestra aislamiento por terminal vía RLS (`SET app.terminal_asignada = '2'`), y recibe `permission denied` al intentar `DELETE`, modificar catálogos, invocar `puerto.descifrar()`, leer vistas seguras o leer el esquema `global`.
   - **`admin_user` (`rol_admin`)**: consulta `VistaAgenteSeguro`, `VistaDetalleMercanciaSeguro`, `global.*` y `BitacoraAuditoria`, pero recibe `permission denied` al intentar borrar la bitácora o leer directamente la llave maestra en `seguridad_interna."ConfigCifrado"`.
