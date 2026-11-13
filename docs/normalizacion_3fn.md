# Normalización a 3FN, tipos de datos y fragmentación

Proyecto: Sistema de Logística Portuaria y Aduanera (IF0010 – Bases de Datos II).
Documento del Rol 1. Describe el DDL de `sql/01_ddl/`.
Los nombres de tablas y columnas siguen el Estándar de Nomenclatura del proyecto (PascalCase y prefijos `CI_`, `CT_`, `CB_`, `CD_`, `CF_`); ver `docs/diccionario_datos.md`.

## 1. Las tres formas normales, con ejemplos del proyecto

**1FN – valores atómicos, sin grupos repetidos.**
Violación: un manifiesto con una columna `contenedores = 'MOIU0000010, MOIU0000023, ...'`.
Solución en el modelo: `Contenedor` es una tabla aparte (relación 1:N con `ManifiestoCarga`). Por la misma razón `CT_Nombre` y `CT_Apellidos` van en columnas separadas, y los datos cifrados (`CT_*Enc`, tipo `BYTEA`) son un único valor opaco por celda.

**2FN – 1FN + ningún atributo depende de una parte de la clave.**
Violación hipotética: si `DetalleMercancia` tuviera clave compuesta `(CI_IdContenedor, CT_CodigoHs)` y guardara `CT_DescripcionPartida`, ese atributo dependería solo de `CT_CodigoHs` (dependencia parcial).
Solución en el modelo: la descripción y la tasa viven en el catálogo `PartidaArancelaria`. Además, **todas las tablas tienen clave primaria de una sola columna**, así que no puede existir dependencia parcial en ninguna.

**3FN – 2FN + ningún atributo no clave depende de otro atributo no clave.**
Violación hipotética A: `ManifiestoCarga` con `CI_IdBuque` y `CT_NombreNaviera` (porque `CI_IdBuque → CI_IdNaviera → CT_Nombre`).
Violación hipotética B (la que sí tuvimos que evitar): `Contenedor` con su propio `CI_IdTerminalMaritima`, ya que `Contenedor → ManifiestoCarga → TerminalMaritima`.
Solución en el modelo: cada hecho se guarda una sola vez, en la tabla cuya clave lo determina (ver sección 4).

## 2. Dependencias funcionales por entidad

PK = clave primaria; CK = clave candidata (`UNIQUE`). Notación `A → B`: A determina B.

| Tabla | Dependencias funcionales | Determinantes que no son PK |
|---|---|---|
| `Pais` | `CI_IdPais → CT_CodigoIso, CT_Nombre` | `CT_CodigoIso` (CK) |
| `TipoContenedor` | `CI_IdTipoContenedor → CT_Codigo, CT_Descripcion, CI_LongitudPies` | `CT_Codigo` (CK) |
| `EstadoContenedor` | `CI_IdEstadoContenedor → CT_Codigo, CT_Descripcion` | `CT_Codigo` (CK) |
| `TipoInspeccion` | `CI_IdTipoInspeccion → CT_Codigo, CT_Descripcion` | `CT_Codigo` (CK) |
| `PartidaArancelaria` | `CI_IdPartidaArancelaria → CT_CodigoHs, CT_Descripcion, CD_TasaArancelPct` | `CT_CodigoHs` (CK) |
| `TerminalMaritima` | `CI_IdTerminalMaritima → CT_Codigo, CT_Nombre, CT_Provincia` | `CT_Codigo` (CK) |
| `DependenciaAduanera` | `CI_IdDependenciaAduanera → CI_IdTerminalMaritima, CT_Codigo, CT_Nombre` | `CT_Codigo` (CK) |
| `Naviera` | `CI_IdNaviera → CI_IdPais, CT_Nombre, CT_CedulaJuridica` | `CT_CedulaJuridica` (CK) |
| `Buque` | `CI_IdBuque → CI_IdNaviera, CI_IdPaisBandera, CT_Nombre, CT_NumeroImo, CI_CapacidadTeu` | `CT_NumeroImo` (CK) |
| `AgenteAduanero` | `CI_IdAgenteAduanero → CT_CodigoLicencia, CT_Nombre, CT_Apellidos, CT_Correo, CT_CedulaEnc, CT_TelefonoEnc, CB_Activo` | `CT_CodigoLicencia`, `CT_Correo` (CK) |
| `ManifiestoCarga` | `CI_IdManifiestoCarga → CI_IdTerminalMaritima, CI_IdBuque, CI_IdAgenteAduanero, CT_NumeroManifiesto, CT_PuertoOrigen, CF_FechaArribo, CF_FechaRegistro, CT_Estado` | `CT_NumeroManifiesto` (CK) |
| `Contenedor` | `CI_IdContenedor → CI_IdManifiestoCarga, CI_IdTipoContenedor, CI_IdEstadoContenedor, CT_NumeroIso, CD_TaraKg, CD_PesoMaxKg, CB_RequiereRefrigeracion, CD_TemperaturaC` | `CT_NumeroIso` (CK) |
| `DetalleMercancia` | `CI_IdDetalleMercancia → CI_IdContenedor, CI_IdPartidaArancelaria, CT_Descripcion, CI_Cantidad, CD_PesoKg, CT_ValorDeclaradoEnc, CT_ValorArancelarioEnc, CT_EstadoInventario` | ninguno |
| `InspeccionTransito` | `CI_IdInspeccionTransito → CI_IdContenedor, CI_IdTipoInspeccion, CI_IdAgenteAduanero, CF_FechaHora, CT_Resultado, CT_Observaciones` | ninguno |

## 3. Justificación de 3FN por tabla

En todas las tablas, **todo determinante es la PK o una clave candidata**; por lo tanto cada tabla cumple 3FN (incluso BCNF) salvo los puntos discutidos en la sección 4.

- **Catálogos** (`Pais`, `TipoContenedor`, `EstadoContenedor`, `TipoInspeccion`, `PartidaArancelaria`): solo dependen de su PK; `CT_Codigo` y `CT_CodigoHs` son claves naturales alternativas.
- **`TerminalMaritima`, `DependenciaAduanera`**: la dependencia solo guarda la FK a su terminal; el nombre de la terminal no se repite.
- **`Naviera`, `Buque`**: el buque guarda `CI_IdNaviera` (no el nombre de la naviera). `CI_IdPaisBandera` (bandera del buque) y `Naviera.CI_IdPais` (país de la empresa) son hechos independientes: un buque puede tener bandera distinta al país de su naviera (el catálogo incluye, por ejemplo, Liberia).
- **`AgenteAduanero`**: atributos propios del agente; `CT_CedulaEnc` y `CT_TelefonoEnc` son datos sensibles cifrados.
- **`ManifiestoCarga`**: el buque determina la naviera, pero la naviera no se guarda aquí (se obtiene por `Buque`). Ningún atributo no clave determina a otro.
- **`Contenedor`**: ver 4.3 (`CD_PesoMaxKg`, `CB_RequiereRefrigeracion`).
- **`DetalleMercancia`**: descripción, cantidad y peso son propios de la línea; la tasa vive en `PartidaArancelaria`. Ver 4.4 (valor arancelario).
- **`InspeccionTransito`**: bitácora; cada fila depende solo de su PK.

## 4. Decisiones que hay que saber defender

### 4.1 `CI_IdTerminalMaritima` solo en `ManifiestoCarga`
Si `Contenedor`, `DetalleMercancia` e `InspeccionTransito` repitieran `CI_IdTerminalMaritima`, aparecería una dependencia transitiva (`Contenedor → ManifiestoCarga → TerminalMaritima`). Por eso la columna existe únicamente en `ManifiestoCarga` y las demás tablas heredan su fragmento por la cadena de FK. Cada nodo impone `CHECK (CI_IdTerminalMaritima = N)` en el manifiesto, lo que basta para que todo el subárbol pertenezca a una sola terminal.
**Costo:** para filtrar "todas las inspecciones de la terminal X" hay que hacer joins por la cadena de FK; en la práctica cada nodo ya contiene solo su terminal, así que la consulta local no necesita filtro.

### 4.2 El manifiesto no referencia la dependencia aduanera
Si `ManifiestoCarga` guardara a la vez `CI_IdTerminalMaritima` e `CI_IdDependenciaAduanera`, habría otra dependencia transitiva (`ManifiestoCarga → DependenciaAduanera → TerminalMaritima`). El enunciado solo exige la relación Terminal 1:N Dependencia, que se cumple. La dependencia queda relacionada únicamente con su terminal.

### 4.3 `CD_PesoMaxKg` y `CB_RequiereRefrigeracion` dentro de `Contenedor`
El enunciado los pide como atributos del contenedor. Se justifican como propiedades de **cada unidad física**: el peso bruto máximo es el de la placa de ese contenedor concreto y la refrigeración es una necesidad operativa de esa unidad, no una propiedad fija del tipo. Si se considerara que el tipo determina ambos, habría que moverlos a `TipoContenedor`.
Los datos de prueba sí usan valores iguales por tipo (30 480 kg para 20 pies y 32 500 kg para 40 pies), pero eso es una decisión del generador, no una regla del modelo.

### 4.4 `CT_ValorArancelarioEnc` es un atributo derivado
Conceptualmente `valor arancelario = valor declarado × CD_TasaArancelPct / 100`, así que depende de otro atributo de la fila y de la tasa del catálogo. Se almacena porque (a) el enunciado lo nombra como columna sensible a cifrar y (b) conserva el monto liquidado aunque la tasa del catálogo cambie después. Al estar cifrado, no puede recalcularse con una vista sin descifrar. Es una redundancia deliberada y documentada.

### 4.5 Estados y tipos
`EstadoContenedor` y `TipoInspeccion` son catálogos (requisito del plan). `CT_Estado` del manifiesto, `CT_EstadoInventario` y `CT_Resultado` quedan como `VARCHAR` con `CHECK` de lista cerrada, porque no tienen atributos propios (no hay dependencia que aislar).
`CT_EstadoInventario` se guarda por línea de mercancía porque el bloqueo y la liberación operan sobre inventario. Los datos iniciales siguen la regla `RETENIDO → BLOQUEADO`, `DESPACHADO → DESPACHADO`, resto `DISPONIBLE`; esa misma regla debe aplicar el trigger del Rol 3 (confirmar con el Rol 3).

### 4.6 `CT_PuertoOrigen` como texto
Es un valor libre sin atributos dependientes; no viola 3FN. Podría pasar a catálogo para evitar variantes de escritura, pero el enunciado no lo exige.

## 5. Tipos de datos

| Dato | Tipo | Motivo |
|---|---|---|
| Pesos (`CD_TaraKg`, `CD_PesoMaxKg`, `CD_PesoKg`) | `NUMERIC(10,2)` | Exacto: sin errores de redondeo de `FLOAT`, y las comparaciones de sobrepeso son confiables |
| Tasa de arancel | `NUMERIC(5,2)` | Porcentaje exacto |
| Valores monetarios | texto de un `NUMERIC` cifrado en `BYTEA` | Se cifra la representación decimal |
| Fechas | `TIMESTAMPTZ` | Guarda la zona horaria; necesario con nodos en contenedores distintos |
| Temperatura | `NUMERIC(4,1)` | Un decimal |
| IDs de tablas operativas | `BIGINT` (identity) | Rangos de 10⁹ por nodo no caben en `INT` |
| Número ISO | `CHAR(11)` con `CHECK '^[A-Z]{4}[0-9]{7}$'` | 4 letras + 7 dígitos, longitud fija |

**ISO 6346:** tres letras de propietario, una letra de categoría (U para contenedores), seis dígitos de serie y un dígito de control. La base de datos **valida el formato**, pero **no calcula el dígito de control**: en los datos de prueba el último dígito es solo `g % 10`. Un dígito de control real sería una mejora opcional.

## 6. Fragmentación horizontal por terminal

**Qué es.** Dividir las *filas* de una tabla entre nodos según un criterio, manteniendo todas las columnas. Aquí el criterio es la terminal: cada nodo guarda solo los manifiestos de su terminal y todo lo que cuelga de ellos (contenedores, detalles e inspecciones).

**Por qué por terminal.**
- En el modelo cada contenedor pertenece a un manifiesto y cada manifiesto a una sola terminal, así que ninguna consulta ni transacción operativa necesita cruzar fragmentos.
- Regla de escritura: cada terminal se escribe **solo en su primario**. Ninguna transacción escribe en dos fragmentos, por lo que no hace falta commit en dos fases y se conserva ACID local.
- Las llaves foráneas nunca cruzan fragmentos: toda la cadena `manifiesto → Contenedor → detalle/inspección` vive en el mismo nodo.

**Qué se replica.** Los catálogos y las entidades comunes (terminales, dependencias, navieras, buques, agentes) se cargan idénticos en los 3 nodos, de modo que las FK se resuelven localmente.

**Unicidad de IDs.** Cada nodo tiene su rango: nodo N usa `[N × 10⁹, N × 10⁹ + 999 999 999]`, impuesto con `MINVALUE`/`MAXVALUE` de la secuencia. Los IDs son únicos globalmente sin coordinación.

**Ventajas.** Localidad de datos; carga repartida entre nodos; un nodo caído afecta solo a su terminal; sin transacciones distribuidas.

**Costos.**
- Las consultas globales (ver todas las terminales) requieren unir los nodos (`postgres_fdw` y vistas `UNION ALL`, decisión del Rol 2).
- El reparto no es uniforme: Moín concentra más datos (300 manifiestos frente a 150 y 80 en los datos de prueba), por lo que el nodo 1 tiene más carga.
- Los datos comunes se modifican en 3 lugares y hay que mantenerlos sincronizados.
- Mover un manifiesto entre terminales exigiría reescribir IDs, porque estos pertenecen al rango del nodo.
- Los datos cifrados de `AgenteAduanero` no son byte a byte iguales entre nodos (el cifrado no es determinista), aunque el texto plano sí coincide.
