# Diccionario de datos

Esquema `puerto`, PostgreSQL 16. Nomenclatura según el **Estándar de Nomenclatura para Bases de Datos** del proyecto.

**Grupos:** 🟦 Catálogo (idéntico en los 3 nodos) · 🟩 Entidad común (idéntica en los 3 nodos, IDs fijos) · 🟧 Fragmentada (cada nodo guarda solo su terminal).
**Clave:** PK = primaria · FK = foránea · UQ = única.

## Nomenclatura aplicada

- **Tablas:** `PascalCase`, en singular (`ManifiestoCarga`). No hay tablas de relación (`X`) porque el modelo no tiene relaciones N:M.
- **Columnas:** `[Prefijo]_[NombreCampo]` con prefijo `CI` (entero), `CT` (texto), `CB` (booleano), `CD` (decimal), `CF` (fecha/timestamp). Una FK lleva el mismo nombre que la PK que referencia (`CI_IdBuque`); la única excepción es `CI_IdPaisBandera`, una FK con rol hacia `Pais`.
- **Restricciones:** `PK_Tabla`, `FK_TablaHija_X_TablaPadre`, `UQ_Tabla_Campo` (según el estándar) y `CK_Tabla_Campo` para los `CHECK`.
- **Índices:** `IX_Tabla_Campo`.
- **Identificadores entre comillas dobles:** PostgreSQL pasa a minúsculas todo identificador sin comillas, así que para conservar mayúsculas hay que escribir `puerto."ManifiestoCarga"` y `"CI_IdBuque"` en todas las consultas, vistas, procedimientos y definiciones de `postgres_fdw`.
- **Decisiones que el estándar no cubre** (confirmar con el equipo): (1) las columnas cifradas son `BYTEA`, que no tiene prefijo propio; se usó `CT_` porque guardan texto cifrado. (2) Los nombres `CK_` e `IX_` siguen el mismo patrón que `UQ_`.
- Esquema (`puerto`) y funciones (`puerto.cifrar`, `puerto.descifrar`) no están cubiertos por el estándar y se mantienen.

IDs de tablas fragmentadas: el nodo N usa el rango `[N × 10⁹, N × 10⁹ + 999 999 999]` (identity con `MINVALUE`/`MAXVALUE`).


---

## 🟦 Catálogos

### `Pais`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdPais | SMALLINT | No | PK | Identificador |
| CT_CodigoIso | CHAR(2) | No | UQ | Código ISO 3166 de 2 letras |
| CT_Nombre | VARCHAR(60) | No |  | Nombre del país |

Restricciones: `PK_Pais`, `UQ_Pais_CT_CodigoIso`

### `TipoContenedor`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdTipoContenedor | SMALLINT | No | PK | Identificador |
| CT_Codigo | VARCHAR(5) | No | UQ | 20GP, 40GP, 40HC, 20RF, 40RF |
| CT_Descripcion | VARCHAR(60) | No |  | Descripción |
| CI_LongitudPies | SMALLINT | No |  | 20 o 40 |

Restricciones: `PK_TipoContenedor`, `UQ_TipoContenedor_CT_Codigo`, `CK_TipoContenedor_CI_LongitudPies`

### `EstadoContenedor`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdEstadoContenedor | SMALLINT | No | PK | Identificador |
| CT_Codigo | VARCHAR(20) | No | UQ | Código del estado |
| CT_Descripcion | VARCHAR(80) | No |  | Descripción |

Valores: 1 `EN_BUQUE`, 2 `DESCARGADO`, 3 `EN_PATIO`, 4 `EN_INSPECCION`, 5 `RETENIDO`, 6 `LIBERADO`, 7 `DESPACHADO`.
Regla de inventario usada en la carga: `RETENIDO → BLOQUEADO`, `DESPACHADO → DESPACHADO`, resto `DISPONIBLE`.

Restricciones: `PK_EstadoContenedor`, `UQ_EstadoContenedor_CT_Codigo`

### `TipoInspeccion`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdTipoInspeccion | SMALLINT | No | PK | Identificador |
| CT_Codigo | VARCHAR(20) | No | UQ | Código del tipo |
| CT_Descripcion | VARCHAR(100) | No |  | Descripción |

Valores: 1 `INGRESO`, 2 `REVISION_FISICA`, 3 `RETENCION`, 4 `LIBERACION`, 5 `DESPACHO`.

Restricciones: `PK_TipoInspeccion`, `UQ_TipoInspeccion_CT_Codigo`

### `PartidaArancelaria`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdPartidaArancelaria | SMALLINT | No | PK | Identificador (1 y 2 son las partidas refrigeradas) |
| CT_CodigoHs | VARCHAR(10) | No | UQ | Código del Sistema Armonizado |
| CT_Descripcion | VARCHAR(100) | No |  | Descripción de la partida |
| CD_TasaArancelPct | NUMERIC(5,2) | No |  | Porcentaje de arancel, `>= 0` |

Las 16 partidas y sus tasas son **datos de prueba**, no un arancel oficial.

Restricciones: `PK_PartidaArancelaria`, `UQ_PartidaArancelaria_CT_CodigoHs`, `CK_PartidaArancelaria_CD_TasaArancelPct`


---

## 🟩 Entidades comunes

### `TerminalMaritima`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdTerminalMaritima | SMALLINT | No | PK | 1 = Moín, 2 = Limón, 3 = Caldera. Coincide con el número de nodo |
| CT_Codigo | VARCHAR(5) | No | UQ | MOI, LIM, CAL |
| CT_Nombre | VARCHAR(80) | No |  | Nombre de la terminal |
| CT_Provincia | VARCHAR(40) | No |  | Provincia |

Restricciones: `PK_TerminalMaritima`, `UQ_TerminalMaritima_CT_Codigo`

### `DependenciaAduanera`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdDependenciaAduanera | SMALLINT | No | PK | 1-2 Moín, 3-4 Limón, 5-6 Caldera |
| CI_IdTerminalMaritima | SMALLINT | No | FK → TerminalMaritima | Terminal a la que pertenece |
| CT_Codigo | VARCHAR(10) | No | UQ | Ej. `DA-T1-A` |
| CT_Nombre | VARCHAR(80) | No |  | Nombre de la oficina |

Restricciones: `PK_DependenciaAduanera`, `UQ_DependenciaAduanera_CT_Codigo`, `FK_DependenciaAduanera_X_TerminalMaritima`

### `Naviera`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdNaviera | INT | No | PK | Identificador |
| CI_IdPais | SMALLINT | No | FK → Pais | País de la empresa |
| CT_Nombre | VARCHAR(80) | No |  | Razón social |
| CT_CedulaJuridica | VARCHAR(15) | No | UQ | Cédula jurídica |

Restricciones: `PK_Naviera`, `UQ_Naviera_CT_CedulaJuridica`, `FK_Naviera_X_Pais`

### `Buque`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdBuque | INT | No | PK | Identificador |
| CI_IdNaviera | INT | No | FK → Naviera | Naviera que lo administra |
| CI_IdPaisBandera | SMALLINT | No | FK → Pais | País de la bandera (FK con rol) |
| CT_Nombre | VARCHAR(80) | No |  | Nombre del buque |
| CT_NumeroImo | CHAR(7) | No | UQ | Número IMO (7 dígitos) |
| CI_CapacidadTeu | INT | No |  | Capacidad en TEU, `> 0` |

Restricciones: `PK_Buque`, `UQ_Buque_CT_NumeroImo`, `CK_Buque_CI_CapacidadTeu`, `FK_Buque_X_Naviera`, `FK_Buque_X_Pais`

### `AgenteAduanero`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdAgenteAduanero | INT | No | PK | Identificador |
| CT_CodigoLicencia | VARCHAR(12) | No | UQ | Licencia (`AA-NNNNN`) |
| CT_Nombre | VARCHAR(60) | No |  | Nombre |
| CT_Apellidos | VARCHAR(80) | No |  | Apellidos |
| CT_Correo | VARCHAR(100) | No | UQ | Correo electrónico |
| CT_CedulaEnc | BYTEA | No |  | **Cifrado.** Cédula, vía `puerto.cifrar()` |
| CT_TelefonoEnc | BYTEA | No |  | **Cifrado.** Teléfono, vía `puerto.cifrar()` |
| CB_Activo | BOOLEAN | No |  | Por defecto `TRUE` |

Restricciones: `PK_AgenteAduanero`, `UQ_AgenteAduanero_CT_CodigoLicencia`, `UQ_AgenteAduanero_CT_Correo`


---

## 🟧 Tablas fragmentadas

### `ManifiestoCarga`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdManifiestoCarga | BIGINT | No | PK | Identity del rango del nodo |
| CI_IdTerminalMaritima | SMALLINT | No | FK → TerminalMaritima | **Única columna de fragmento.** `CHECK (= N)` en el nodo N |
| CI_IdBuque | INT | No | FK → Buque | Buque que arriba |
| CI_IdAgenteAduanero | INT | No | FK → AgenteAduanero | Agente que gestiona el manifiesto |
| CT_NumeroManifiesto | VARCHAR(20) | No | UQ | Formato `MAN-T<nodo>-NNNNNN` |
| CT_PuertoOrigen | VARCHAR(60) | No |  | Puerto de origen |
| CF_FechaArribo | TIMESTAMPTZ | No |  | Arribo del buque |
| CF_FechaRegistro | TIMESTAMPTZ | No |  | Por defecto `now()` |
| CT_Estado | VARCHAR(20) | No |  | `REGISTRADO`, `EN_DESCARGA`, `EN_INSPECCION`, `DESPACHO_PARCIAL`, `CERRADO` (por defecto `REGISTRADO`) |

Restricciones: `PK_ManifiestoCarga`, `UQ_ManifiestoCarga_CT_NumeroManifiesto`, `CK_ManifiestoCarga_Fragmento`, `CK_ManifiestoCarga_CT_Estado`, `FK_ManifiestoCarga_X_TerminalMaritima`, `FK_ManifiestoCarga_X_Buque`, `FK_ManifiestoCarga_X_AgenteAduanero`

### `Contenedor`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdContenedor | BIGINT | No | PK | Identity del rango del nodo |
| CI_IdManifiestoCarga | BIGINT | No | FK → ManifiestoCarga | Manifiesto que lo ampara |
| CI_IdTipoContenedor | SMALLINT | No | FK → TipoContenedor | Tipo |
| CI_IdEstadoContenedor | SMALLINT | No | FK → EstadoContenedor | Estado aduanero (por defecto 1 = `EN_BUQUE`) |
| CT_NumeroIso | CHAR(11) | No | UQ | 4 letras + 7 dígitos (`CHECK` de formato) |
| CD_TaraKg | NUMERIC(10,2) | No |  | Peso vacío, `> 0` |
| CD_PesoMaxKg | NUMERIC(10,2) | No |  | Peso bruto máximo, `> CD_TaraKg` |
| CB_RequiereRefrigeracion | BOOLEAN | No |  | Por defecto `FALSE` |
| CD_TemperaturaC | NUMERIC(4,1) | Sí |  | Obligatoria si requiere refrigeración; `NULL` si no |

Restricciones: `PK_Contenedor`, `UQ_Contenedor_CT_NumeroIso`, `CK_Contenedor_CT_NumeroIso`, `CK_Contenedor_CD_TaraKg`, `CK_Contenedor_CD_PesoMaxKg`, `CK_Contenedor_CB_RequiereRefrigeracion`, `FK_Contenedor_X_ManifiestoCarga`, `FK_Contenedor_X_TipoContenedor`, `FK_Contenedor_X_EstadoContenedor`

### `DetalleMercancia`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdDetalleMercancia | BIGINT | No | PK | Identity del rango del nodo |
| CI_IdContenedor | BIGINT | No | FK → Contenedor | Contenedor que la almacena |
| CI_IdPartidaArancelaria | SMALLINT | No | FK → PartidaArancelaria | Partida arancelaria |
| CT_Descripcion | VARCHAR(120) | No |  | Descripción de la línea |
| CI_Cantidad | INT | No |  | `> 0` |
| CD_PesoKg | NUMERIC(10,2) | No |  | `> 0` |
| CT_ValorDeclaradoEnc | BYTEA | No |  | **Cifrado.** Valor declarado |
| CT_ValorArancelarioEnc | BYTEA | No |  | **Cifrado.** Valor arancelario liquidado |
| CT_EstadoInventario | VARCHAR(12) | No |  | `DISPONIBLE`, `BLOQUEADO`, `DESPACHADO` (por defecto `DISPONIBLE`) |

Restricciones: `PK_DetalleMercancia`, `CK_DetalleMercancia_CI_Cantidad`, `CK_DetalleMercancia_CD_PesoKg`, `CK_DetalleMercancia_CT_EstadoInventario`, `FK_DetalleMercancia_X_Contenedor`, `FK_DetalleMercancia_X_PartidaArancelaria`

### `InspeccionTransito`
| Columna | Tipo | Nulo | Clave | Descripción |
|---|---|---|---|---|
| CI_IdInspeccionTransito | BIGINT | No | PK | Identity del rango del nodo |
| CI_IdContenedor | BIGINT | No | FK → Contenedor | Contenedor inspeccionado |
| CI_IdTipoInspeccion | SMALLINT | No | FK → TipoInspeccion | Tipo de movimiento |
| CI_IdAgenteAduanero | INT | Sí | FK → AgenteAduanero | Agente que la realiza (puede ser nulo) |
| CF_FechaHora | TIMESTAMPTZ | No |  | Por defecto `now()` |
| CT_Resultado | VARCHAR(12) | No |  | `CONFORME`, `OBSERVACION`, `RETENIDO`, `AUTORIZADO` |
| CT_Observaciones | TEXT | Sí |  | Texto libre |

Restricciones: `PK_InspeccionTransito`, `CK_InspeccionTransito_CT_Resultado`, `FK_InspeccionTransito_X_Contenedor`, `FK_InspeccionTransito_X_TipoInspeccion`, `FK_InspeccionTransito_X_AgenteAduanero`

---

## Funciones de cifrado

| Función | Descripción |
|---|---|
| `puerto.cifrar(texto) → BYTEA` | Cifra con `pgp_sym_encrypt` (pgcrypto). **Es un stub de desarrollo**: el Rol 3 reemplaza el cuerpo sin cambiar nombre ni firma |
| `puerto.descifrar(bytea) → TEXT` | Descifra con `pgp_sym_decrypt` |

## Índices (además de los de PK y UQ)

| Índice | Tabla (columnas) |
|---|---|
| IX_DependenciaAduanera_CI_IdTerminalMaritima | DependenciaAduanera (CI_IdTerminalMaritima) |
| IX_Buque_CI_IdNaviera | Buque (CI_IdNaviera) |
| IX_ManifiestoCarga_CI_IdBuque | ManifiestoCarga (CI_IdBuque) |
| IX_ManifiestoCarga_CI_IdAgenteAduanero | ManifiestoCarga (CI_IdAgenteAduanero) |
| IX_Contenedor_CI_IdManifiestoCarga | Contenedor (CI_IdManifiestoCarga) |
| IX_Contenedor_CI_IdEstadoContenedor | Contenedor (CI_IdEstadoContenedor) |
| IX_DetalleMercancia_CI_IdContenedor | DetalleMercancia (CI_IdContenedor) |
| IX_DetalleMercancia_CI_IdPartidaArancelaria | DetalleMercancia (CI_IdPartidaArancelaria) |
| IX_InspeccionTransito_CI_IdContenedor | InspeccionTransito (CI_IdContenedor, CF_FechaHora DESC) |

Su justificación con `EXPLAIN (ANALYZE, BUFFERS)` se documenta en el README.
