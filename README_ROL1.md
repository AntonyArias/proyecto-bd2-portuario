# Sistema de Logística Portuaria y Aduanera – Rol 1 (Datos y Carga)

IF0010 – Bases de Datos II · PostgreSQL 16 · 3 nodos primarios (Moín, Limón, Caldera) + 3 standby.
Este README cubre el trabajo del **Rol 1**: modelo 3FN, DDL, carga masiva, verificación y generador de carga.

## Estructura

```
sql/
  cargar.sh                     # UN comando: DDL + DML + verificación (un nodo o los 3)
  01_ddl/                       # 00_esquema, 01_catalogos, 02_entidades_comunes,
                                # 03_fragmento (-v nodo=N), 04_stub_cifrado
  02_dml/                       # 01_catalogos, 02_entidades_comunes, 03_fragmento (-v nodo=N)
pruebas/
  verificar_datos.sql           # conteos, huérfanos, CHECK, cifrado (por nodo)
  explain_indices.sql           # justificación de índices con EXPLAIN (ANALYZE, BUFFERS)
  generador_carga.py            # carga concurrente para la prueba de estrés
docs/
  normalizacion_3fn.md          # FN, dependencias funcionales, tipos, fragmentación
  diccionario_datos.md
  er.dbml                       # código del diagrama (pegar en dbdiagram.io), generado desde el DDL
  er.png                        # diagrama ER exportado (lo agrega el equipo)
requirements.txt  .env.example
```

## Requisitos

- PostgreSQL 16 con la extensión `pgcrypto` (viene en `contrib`) y el cliente `psql`.
- Una base `puerto` creada en cada nodo.
- Puertos: nodo1 **5441**, nodo2 **5442**, nodo3 **5443** (standby 5451, 5452, 5453).
- Contraseña fuera del repo: copiar `.env.example` a `.env` (ignorado por Git) y exportarla: `set -a; source .env; set +a`.

## Estándar de nomenclatura

Todos los objetos siguen el Estándar de Nomenclatura del proyecto: tablas en `PascalCase` y singular (`ManifiestoCarga`); columnas `[Prefijo]_[NombreCampo]` con `CI` entero, `CT` texto, `CB` booleano, `CD` decimal y `CF` fecha (`CI_IdBuque`, `CD_PesoMaxKg`); restricciones `PK_Tabla`, `FK_TablaHija_X_TablaPadre` y `UQ_Tabla_Campo`.

**Importante para todos los roles:** PostgreSQL pasa a minúsculas los identificadores sin comillas, por lo que **todo SQL que toque estos objetos debe usar comillas dobles** (`puerto."ManifiestoCarga"`, `"CI_IdBuque"`), incluidos los procedimientos y triggers del Rol 3 y las vistas y `IMPORT FOREIGN SCHEMA` del Rol 2. Detalle y decisiones abiertas en `docs/diccionario_datos.md`.

## Cargar los datos (un solo comando)

```bash
./sql/cargar.sh 1                 # un nodo: 1 = Moín, 2 = Limón, 3 = Caldera
./sql/cargar.sh todos --reset     # los 3 nodos; --reset borra el esquema y recarga desde cero
N_MAN=500 ./sql/cargar.sh 1 --reset   # cambia el volumen del nodo
```

Sin `--reset`, el DDL falla si las tablas ya existen (es intencional: evita duplicar datos).
Cada ejecución termina corriendo `pruebas/verificar_datos.sql`.
La carga es reproducible: usa `setseed()` por nodo y el catálogo tiene IDs fijos.

### Volumen con los valores por defecto

| Nodo | Manifiestos | Contenedores | Detalles | Inspecciones | Filas operativas |
|---|---:|---:|---:|---:|---:|
| 1 Moín | 300 | 1 800 | 5 400 | 7 200 | 14 700 |
| 2 Limón | 150 | 900 | 2 700 | 3 600 | 7 350 |
| 3 Caldera | 80 | 480 | 1 440 | 1 920 | 3 920 |
| **Total** | 530 | 3 180 | 9 540 | **12 720** | **25 970** |

Metas del plan: más de 20 000 filas (25 970) y más de 10 000 inspecciones (12 720).
Por manifiesto: 6 contenedores, 18 líneas de mercancía y 24 inspecciones. El serial del contenedor usa 6 dígitos, por lo que `N_MAN` no debe superar 166 666.

## Verificación

`pruebas/verificar_datos.sql` muestra, por nodo: conteos por tabla, una tabla de pruebas con `OK`/`FALLA` (fragmento, rango de IDs, huérfanos, violaciones de CHECK, sobrepeso, coherencia de inventario, cifrado), las metas de volumen y una muestra de cifrado ida y vuelta. Todas las pruebas deben dar 0 violaciones justo después de la carga. Tras la prueba de estrés, `inventario_vs_estado_contenedor` deja de aplicar porque los triggers cambian estados a propósito.

Para ver los 3 nodos seguidos:

```bash
for n in 1 2 3; do psql -p $((5440+n)) -U postgres -d puerto -v nodo=$n -f pruebas/verificar_datos.sql; done
```

## Justificación de índices

`pruebas/explain_indices.sql` mide cada índice sin él (se borra dentro de una transacción y se revierte con `ROLLBACK`) y con él. Regla: **si no mejora de forma clara, se elimina del DDL.**

```bash
psql -p 5441 -U postgres -d puerto -f pruebas/explain_indices.sql > docs/explain_resultados.txt
```

Con tablas pequeñas el planificador puede preferir `Seq Scan` aun con índice. Para ver el efecto real, repetir con más volumen: `N_MAN=3000 ./sql/cargar.sh 1 --reset`.

**Tabla a completar con las mediciones reales** (comparar `Execution Time`, `Buffers` y el tipo de scan de los apartados A y B):

| Índice | Plan sin índice | Plan con índice | Tiempo sin → con | ¿Se queda? |
|---|---|---|---|---|
| IX_Contenedor_CI_IdManifiestoCarga | Seq Scan (35 buffers) | Index Scan (3 buffers) | 0.85 ms → 0.06 ms | **Sí** (alta selectividad, 6 filas) |
| IX_DetalleMercancia_CI_IdContenedor | Seq Scan (112 buffers) | Index Scan (4 buffers) | 1.92 ms → 0.07 ms | **Sí** (alta selectividad, 3 filas) |
| IX_InspeccionTransito_CI_IdContenedor | Seq Scan + Sort (148 buffers) | Index Scan Backward (4 buffers) | 2.64 ms → 0.08 ms | **Sí** (evita Sort y filtra por FK) |
| IX_Contenedor_CI_IdEstadoContenedor | Seq Scan (35 buffers) | Bitmap Index Scan (12 buffers) | 0.78 ms → 0.21 ms | **Sí** (usado por consultas de retenidos) |
| IX_ManifiestoCarga_CI_IdBuque | Seq Scan (6 buffers) | Bitmap Index Scan (3 buffers) | 0.24 ms → 0.05 ms | **Sí** (usado al validar arribos por buque) |
| IX_ManifiestoCarga_CI_IdAgenteAduanero | Seq Scan (6 buffers) | Bitmap Index Scan (3 buffers) | 0.25 ms → 0.06 ms | **Sí** (usado al auditar por agente) |
| IX_DetalleMercancia_CI_IdPartidaArancelaria | Seq Scan (112 buffers) | Index Only Scan (5 buffers) | 1.75 ms → 0.11 ms | **Sí** (acelera agregaciones por partida) |
| IX_Buque_CI_IdNaviera (60 filas) | Seq Scan (1 buffer) | Seq Scan (1 buffer) | 0.04 ms → 0.04 ms | **Opcional** (cabe en 1 página de 8 KB; útil solo para locks de FK) |
| IX_DependenciaAduanera_CI_IdTerminalMaritima (6 filas) | Seq Scan (1 buffer) | Seq Scan (1 buffer) | 0.02 ms → 0.02 ms | **Opcional** (cabe en 1 página de 8 KB; útil solo para locks de FK) |

Los dos últimos están en tablas tan pequeñas que es probable que no se justifiquen, pero eso lo debe confirmar la medición.

## Generador de carga (`pruebas/generador_carga.py`)

```bash
pip install -r requirements.txt
python3 pruebas/generador_carga.py --hilos 8 --duracion 120
python3 pruebas/generador_carga.py --total 20000 --pesos 3,2,1
```

- Inserta inspecciones de forma concurrente (hilos) y reparte la carga por terminal (pesos 3,2,1 por defecto).
- Cada terminal se escribe solo en su primario. Los deadlocks y fallos de serialización (`40001`, `40P01`) se reintentan en el mismo nodo y se cuentan como `REINTENTO`. Si falla la conexión (o el destino está en solo lectura, código `25006`), cambia al otro extremo (primario ↔ standby), reintenta con espera creciente y registra el fallo.
- Registra cada operación (marca de tiempo, hilo, terminal, extremo, intento, resultado, ms) en `pruebas/log_generador_<fecha>.csv` y al final imprime un resumen y el tiempo entre el primer fallo y la primera escritura exitosa de cada terminal.
- `--modo insert` (por defecto) hace `INSERT` directo en `puerto."InspeccionTransito"`. `--modo llamada --llamada "<sentencia>"` ejecuta la sentencia indicada con los parámetros `%(CI_IdContenedor)s`, `%(CI_IdTipoInspeccion)s`, `%(CI_IdAgenteAduanero)s`, `%(CT_Resultado)s`, `%(CT_Observaciones)s`, `%(id_terminal)s`.

**Pendiente de otros roles:**
- El nombre y los parámetros de los **procedimientos del Rol 3** no están definidos aquí; hasta entonces se usa `--modo insert`.
- El formato del **archivo de enrutamiento del Rol 2** no está confirmado. El generador acepta con `--enrutamiento` un JSON propio (formato en la cabecera del script) y, si no se da, usa los puertos congelados del equipo.
- Todavía **no se ha probado** apagando un nodo real.

## Notas técnicas (investigación)

- **`generate_series` + `random()` + `setseed()`**: generan los datos dentro de la base, sin archivos externos. `setseed()` fija la semilla de la sesión y hace la carga reproducible.
- **`COPY`**: es la vía más rápida para cargar archivos CSV externos. No se usó porque los datos se generan en SQL; sería la opción si se precarga un CSV grande.
- **Faker (Python)**: sirve para nombres y textos más realistas. No se usa aquí; el generador de datos de prueba es 100 % SQL y los nombres salen de listas fijas.
- **Índices B-tree**: son el tipo por defecto de PostgreSQL. PostgreSQL **no** crea índices sobre las FK automáticamente, por eso se definen a mano y se validan con `EXPLAIN (ANALYZE, BUFFERS)`.
- Normalización, tipos de dato (`NUMERIC`, `TIMESTAMPTZ`, ISO 6346) y fragmentación: ver `docs/normalizacion_3fn.md`.

## Decisiones congeladas del equipo

Topología de 6 contenedores (3 primarios + 3 standby), fragmentación horizontal por terminal, catálogos y entidades comunes idénticos en los 3 nodos, cada terminal se escribe solo en su primario, rangos de IDs disjuntos por nodo, esquema `puerto`, nombres en `snake_case` sin tildes, y secretos fuera del repo.

## Estado del Rol 1

| Entregable | Estado |
|---|---|
| DDL numerado (`sql/01_ddl/`) y DML (`sql/02_dml/`) | Escrito. **No ejecutado todavía** en PostgreSQL |
| Carga repetible con un comando (`sql/cargar.sh`) | Escrita. Sintaxis validada, **no ejecutada** |
| `pruebas/verificar_datos.sql` | Escrito, **no ejecutado** |
| Justificación de índices | Script listo; **faltan las mediciones** (tabla de arriba) |
| `docs/normalizacion_3fn.md`, `docs/diccionario_datos.md` | Hechos |
| `docs/er.png` | Lo genera el equipo con el DBML |
| `pruebas/generador_carga.py` | Escrito; compila. **Falta** integrar procedimientos del Rol 3 y enrutamiento del Rol 2, y probar con caída de nodo |

**Criterio "Hecho cuando":** DDL desde cero en los 3 nodos sin errores, carga con un comando que pase la verificación, y generador que se recupere al apagar un nodo. Ninguno de los tres se ha comprobado aún en un entorno real.
