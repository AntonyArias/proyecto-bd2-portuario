# Matriz de Privilegios y Políticas de Seguridad (Rol 3)

Proyecto: **Sistema de Logística Portuaria y Aduanera** (`IF0010` – Bases de Datos II, UCR Sede del Caribe)  
Principio rector: **Menor Privilegio (RBAC + DAC + RLS)** + **Cifrado en reposo (pgcrypto AES-256)** + **Cifrado en tránsito (SSL/TLS + SCRAM-SHA-256)**.

---

## 1. Roles y Usuarios de Ejemplo

| Rol Funcional (`NOLOGIN`) | Usuario de Demostración (`LOGIN`) | Propósito |
|---|---|---|
| `rol_lectura` | `auditor_user` | Consulta y auditoría externa de operaciones; columnas sensibles permanecen opacas (`BYTEA`). |
| `rol_operador` | `operador_user` | Operación portuaria diaria (manifiestos, inspecciones, despachos); sin borrados ni acceso a datos descifrados. |
| `rol_admin` | `admin_user` | Administración aduanera completa, vistas descifradas, consultas globales FDW y lectura de bitácora. |
| *(interno)* | `replicador` | Cuenta técnica con privilegio `REPLICATION` para streaming WAL TLS entre primarios y standbys. |

> Las contraseñas y la llave de cifrado (`ENC_KEY`) se administran exclusivamente en `infra/.env` (ignorado por Git) usando `infra/.env.example` como plantilla.

---

## 2. Matriz Rol × Objeto × Permiso

| Objeto / Esquema | `PUBLIC` | `rol_lectura` (`auditor_user`) | `rol_operador` (`operador_user`) | `rol_admin` (`admin_user`) |
|---|---|---|---|---|
| Esquema `public` (`CREATE`) | Revocado | — | — | — |
| Esquema `puerto` | Sin acceso | `USAGE` | `USAGE` | `USAGE` |
| Esquema `global` (`postgres_fdw`) | Sin acceso | Sin acceso | Sin acceso | `USAGE`, `SELECT` en vistas globales |
| Esquema `seguridad_interna` (`ConfigCifrado`) | Sin acceso | Sin acceso | Sin acceso | Sin acceso directo (solo vía `SECURITY DEFINER`) |
| **Catálogos** (`Pais`, `TipoContenedor`, `EstadoContenedor`, `TipoInspeccion`, `PartidaArancelaria`) | — | `SELECT` | `SELECT` | `SELECT`, `INSERT`, `UPDATE`, `DELETE` |
| **Entidades comunes** (`TerminalMaritima`, `DependenciaAduanera`, `Naviera`, `Buque`, `AgenteAduanero`) | — | `SELECT` (`CT_*Enc` ilegible) | `SELECT` (`CT_*Enc` ilegible) | `SELECT`, `INSERT`, `UPDATE`, `DELETE` |
| **Tablas operativas** (`ManifiestoCarga`, `Contenedor`, `DetalleMercancia`, `InspeccionTransito`) | — | `SELECT` (`CT_*Enc` ilegible) | `SELECT`, `INSERT`, `UPDATE` (**sin `DELETE`**) | `SELECT`, `INSERT`, `UPDATE`, `DELETE` |
| Secuencias en `puerto` | — | — | `USAGE`, `SELECT` | `USAGE`, `SELECT`, `UPDATE` |
| `puerto."BitacoraAuditoria"` | — | Sin acceso | Sin acceso (escribe vía trigger `SECURITY DEFINER`) | `SELECT` únicamente (**inmutable**: sin `INSERT`/`UPDATE`/`DELETE`) |
| `puerto."VistaAgenteSeguro"` (descifrada) | — | Denegado | Denegado | `SELECT` |
| `puerto."VistaDetalleMercanciaSeguro"` (descifrada) | — | Denegado | Denegado | `SELECT` |
| Función `puerto.cifrar(TEXT)` | — | Denegado | `EXECUTE` | `EXECUTE` |
| Función `puerto.descifrar(BYTEA)` | — | Denegado | Denegado | `EXECUTE` |
| Procedimientos `sp_ingresar_manifiesto`, `sp_despachar_mercancia`, `sp_registrar_inspeccion` | — | Denegado | `EXECUTE` | `EXECUTE` |

---

## 3. Row-Level Security (RLS) en `puerto."ManifiestoCarga"`

| Política | Rol objetivo | Regla aplicada |
|---|---|---|
| `pol_manifiesto_admin` | `rol_admin` | Acceso completo (`USING (true)` / `WITH CHECK (true)`). |
| `pol_manifiesto_lectura` | `rol_lectura` | Lectura de auditoría local (`FOR SELECT USING (true)`). |
| `pol_manifiesto_operador_terminal` | `rol_operador` | Si la sesión fija `SET app.terminal_asignada = 'N'`, solo puede consultar y escribir manifiestos donde `"CI_IdTerminalMaritima" = N`. Si no se fija, aplica el fragmento del nodo local. |

---

## 4. Seguridad en Tránsito y Autenticación (`pg_hba.conf` + PostgreSQL)

Configuración aplicada en los 6 contenedores (`sql/05_seguridad/pg_hba_seguro.conf` e `infra/docker-compose.yml`):

1. **Parámetros obligatorios de instancia:**
   - `ssl = on`
   - `ssl_min_protocol_version = TLSv1.2` (negocia TLSv1.3 en clientes modernos)
   - `password_encryption = scram-sha-256`
2. **Reglas de `pg_hba.conf`:**
   - `local all all trust`: reservado únicamente al socket Unix interno dentro del contenedor para los scripts de administración vía `docker compose exec`.
   - `hostnossl all all all reject` y `hostnossl replication all all reject`: bloquea de forma explícita cualquier intento TCP en texto plano (`sslmode=disable`).
   - `hostssl replication replicador all scram-sha-256`: la réplica física entre primario y standby viaja cifrada por TLS.
   - `hostssl all all all scram-sha-256`: toda conexión TCP de usuarios, `postgres_fdw` y generador de carga exige TLS y autenticación `SCRAM-SHA-256`.
