# Demostraciones Reproducibles de Propiedades ACID (`pruebas/acid/`)

Cada propiedad ACID cuenta con una demostración reproducible en **menos de 2 minutos** (entre 2 y 10 segundos automatizada, o ~1 minuto paso a paso en dos terminales durante la defensa), ejecutándose con el rol operativo de menor privilegio (`operador_user`).

---

## Opción A: Corrida completa en un solo comando (~20 s)

Desde Git Bash en la raíz del repositorio:

```bash
bash pruebas/acid/ejecutar_todas_acid.sh
```

---

## Opción B: Demostración en vivo por propiedad (con 2 sesiones `psql`)

Antes de abrir las terminales en Git Bash, carga las variables locales:

```bash
export MSYS_NO_PATHCONV=1
set -a; source infra/.env; set +a
```

### 1. Atomicidad (`01_atomicidad.sql`) — *Error a mitad = Rollback completo*
Invoca `puerto.sp_ingresar_manifiesto` con **2 contenedores**: el #1 es válido y se inserta temporalmente, pero el #2 excede `peso_max_kg` y dispara el trigger de sobrepeso. Se comprueba que no quedan manifiestos ni contenedores parciales/huérfanos (`0` filas residuales).

```bash
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
  psql -U operador_user -d puerto < pruebas/acid/01_atomicidad.sql
```

### 2. Consistencia (`02_consistencia.sql`) — *Violación de restricciones y reglas*
Intenta quebrantar cuatro invariantes (manifiesto de otra terminal en `nodo1`, formato ISO inválido, mercancía seca en contenedor refrigerado y despacho de un contenedor `RETENIDO`). PostgreSQL rechaza cada intento y las 5 pruebas de integridad cierran en `0` violaciones.

```bash
docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
  psql -U operador_user -d puerto < pruebas/acid/02_consistencia.sql
```

### 3. Aislamiento (`03_aislamiento_*`) — *Dos despachos simultáneos del mismo contenedor*

- **Modo automático (levanta ambas sesiones en paralelo y muestra `pg_stat_activity` en vivo):**
  ```bash
  bash pruebas/acid/03_aislamiento_demo.sh
  ```

- **Modo interactivo con 2 consolas lado a lado (para la defensa):**
  1. **Consola 1** (adquiere `SELECT ... FOR UPDATE` en `sp_despachar_mercancia` y retiene la transacción 8 segundos):
     ```bash
     docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
       psql -U operador_user -d puerto -v espera_seg=8 < pruebas/acid/03_aislamiento_sesion1.sql
     ```
  2. **Consola 2** (ejecutar inmediatamente mientras la Consola 1 espera; gracias a MVCC apunta automáticamente al mismo contenedor, queda bloqueada en el candado de fila y al hacer `COMMIT` la Consola 1 aborta con `SQLSTATE P0006` evitando doble despacho):
     ```bash
     docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
       psql -U operador_user -d puerto < pruebas/acid/03_aislamiento_sesion2.sql
     ```

### 4. Durabilidad (`04_durabilidad_*`) — *COMMIT + apagado forzoso (`SIGKILL`) + recuperación WAL*

- **Modo automático (~10 s):**
  ```bash
  bash pruebas/acid/04_durabilidad_demo.sh
  ```

- **Modo paso a paso con 2 consolas:**
  1. **Consola 1 (inserta y confirma `COMMIT`):**
     ```bash
     docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
       psql -U operador_user -d puerto < pruebas/acid/04_durabilidad_paso1_commit.sql
     ```
  2. **Consola 2 (apagado eléctrico abrupto `SIGKILL`, verificación en `nodo1sb` con primario muerto y reinicio con recovery WAL):**
     ```bash
     docker compose -f infra/docker-compose.yml kill -s SIGKILL nodo1
     docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$AUDITOR_PASS" nodo1sb \
       psql -U auditor_user -d puerto < pruebas/acid/04_durabilidad_paso2_verificar.sql
     docker compose -f infra/docker-compose.yml start nodo1
     sleep 4
     docker compose -f infra/docker-compose.yml exec -T -e PGPASSWORD="$OPERADOR_PASS" nodo1 \
       psql -U operador_user -d puerto < pruebas/acid/04_durabilidad_paso2_verificar.sql
     ```

