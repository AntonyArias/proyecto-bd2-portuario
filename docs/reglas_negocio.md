# Reglas de Negocio y Lógica Transaccional (Rol 3)

Proyecto: **Sistema de Logística Portuaria y Aduanera** (`IF0010` – Bases de Datos II, UCR Sede del Caribe)  
Esquema: `puerto` (nomenclatura oficial `PascalCase` + prefijos `CI_`, `CT_`, `CB_`, `CD_`, `CF_`).

---

## 1. Matriz de Reglas de Negocio Implementadas

| Código | Regla de negocio | Mecanismo en PostgreSQL | SQLSTATE / Error | Referencia |
|---|---|---|---|---|
| **RN-01** | **Localidad de fragmento**: cada nodo solo admite manifiestos de su propia terminal (`1` = Moín, `2` = Limón, `3` = Caldera). Ninguna transacción escribe en dos fragmentos. | `CHECK` `CK_ManifiestoCarga_Fragmento` + validación en `sp_ingresar_manifiesto` y `sp_registrar_inspeccion` | `23514` / `P0001` | `datos/01_ddl.sql`, `01_sp_ingresar_manifiesto.sql`, `04_sp_registrar_inspeccion.sql` |
| **RN-02** | **Agente aduanero autorizado y activo**: todo manifiesto, despacho e inspección nominal exige un agente existente con `"CB_Activo" = TRUE`. | Validación explícita antes de operar | `P0003` | `01_sp_ingresar_manifiesto.sql`, `02_sp_despachar_mercancia.sql`, `04_sp_registrar_inspeccion.sql` |
| **RN-03** | **Buque e identificador ISO 6346 válidos**: el buque debe existir por `"CT_NumeroImo"` y cada contenedor debe cumplir `^[A-Z]{4}[0-9]{7}$`. | `CK_Contenedor_CT_NumeroIso` + validación en SP | `23514` / `P0002` | `datos/01_ddl.sql`, `01_sp_ingresar_manifiesto.sql` |
| **RN-04** | **Manifiesto atómico completo**: todo manifiesto debe ingresar en una sola transacción con $\ge 1$ contenedor, $\ge 1$ línea de `DetalleMercancia` por contenedor y su inspección de `INGRESO` (`1`). Fallo parcial = `ROLLBACK` completo. | Transacción atómica en `sp_ingresar_manifiesto` + `EXCEPTION` que aborta todo el bloque | `P0009` / heredado | `sql/04_rutinas/01_sp_ingresar_manifiesto.sql` |
| **RN-05** | **Peso máximo permitido**: la suma `"CD_TaraKg" + SUM("CD_PesoKg")` de las líneas del contenedor nunca puede superar `"CD_PesoMaxKg"`. | Trigger `BEFORE INSERT OR UPDATE` `trg_validar_detalle_mercancia` (con bloqueo `FOR UPDATE` al contenedor) + `trg_validar_contenedor` + chequeo previo en `sp_despachar_mercancia` | `23514` | `sql/04_rutinas/03_triggers_inventario_y_pesos.sql` |
| **RN-06** | **Cadena de frío obligatoria**: contenedores refrigerados (`20RF`, `40RF`, `"CB_RequiereRefrigeracion" = TRUE`) exigen `"CD_TemperaturaC" IS NOT NULL` y partidas refrigeradas (`1` Bananos, `2` Carne). Contenedores secos prohíben partidas refrigeradas. | `CK_Contenedor_CB_RequiereRefrigeracion` + `trg_validar_detalle_mercancia` + validación de tipo en `sp_ingresar_manifiesto` | `23514` | `01_sp_ingresar_manifiesto.sql`, `03_triggers_inventario_y_pesos.sql` |
| **RN-07** | **Bloqueo automático por retención**: al registrar en `InspeccionTransito` el tipo `3` (`RETENCION`), el resultado se fuerza a `'RETENIDO'`, el contenedor pasa a estado `5` (`RETENIDO`) y todas sus líneas en `DetalleMercancia` pasan a `'BLOQUEADO'`. | Triggers `trg_01_validar_inspeccion` y `trg_02_aplicar_efecto_inspeccion` | Automático | `sql/04_rutinas/03_triggers_inventario_y_pesos.sql` |
| **RN-08** | **Liberación condicionada a retención**: solo un contenedor en estado `5` (`RETENIDO`) puede recibir una inspección tipo `4` (`LIBERACION`); al aplicarse, pasa a estado `6` (`LIBERADO`) y su inventario vuelve a `'DISPONIBLE'`. | Triggers `trg_01_validar_inspeccion` y `trg_02_aplicar_efecto_inspeccion` | `P0008` | `sql/04_rutinas/03_triggers_inventario_y_pesos.sql` |
| **RN-09** | **Prohibición de despacho sobre retenidos / en buque / ya despachados**: no se puede despachar (tipo `5` ni `sp_despachar_mercancia`) un contenedor `RETENIDO` (`5`), `EN_BUQUE` (`1`), `DESPACHADO` (`7`), o con líneas `'BLOQUEADO'`/`'DESPACHADO'`. | `sp_despachar_mercancia` + `trg_01_validar_inspeccion` + `trg_validar_contenedor` | `P0005` / `P0006` / `P0007` | `02_sp_despachar_mercancia.sql`, `03_triggers_inventario_y_pesos.sql` |
| **RN-10** | **Concurrencia sin doble despacho**: dos sesiones concurrentes intentando despachar el mismo contenedor se serializan mediante bloqueo pesimista `SELECT ... FOR UPDATE` sin `JOIN` (`EvalPlanQual` en `READ COMMITTED`). La segunda sesión relee estado `7` y falla. | `SELECT ... FROM puerto."Contenedor" WHERE ... FOR UPDATE` | `P0006` | `sql/04_rutinas/02_sp_despachar_mercancia.sql` |
| **RN-11** | **Inmutabilidad post-despacho y cierre de manifiesto**: al despacharse un contenedor pasa a estado `7` (`DESPACHADO`) y su inventario a `'DESPACHADO'`; no admite nuevas cargas ni reversiones. El manifiesto padre cambia automáticamente a `'DESPACHO_PARCIAL'` o `'CERRADO'`. | `sp_despachar_mercancia` + `trg_validar_contenedor` + `trg_validar_detalle_mercancia` | `P0006` | `02_sp_despachar_mercancia.sql`, `03_triggers_inventario_y_pesos.sql` |
| **RN-12** | **Cifrado obligatorio y cálculo arancelario**: valores declarados, valores arancelarios, cédulas y teléfonos se almacenan cifrados con `pgcrypto` (AES-256). Si no se provee arancel explícito, `sp_ingresar_manifiesto` calcula `valor_declarado * tasa / 100`. | `puerto.cifrar()` / `puerto.descifrar()` con `SECURITY DEFINER` y llave en `seguridad_interna."ConfigCifrado"` | Automático | `01_sp_ingresar_manifiesto.sql`, `01_roles_y_seguridad.sql` |
| **RN-13** | **Auditoría inmutable**: cada creación o cambio de estado en `ManifiestoCarga` y `Contenedor` queda registrado en `BitacoraAuditoria` con usuario, rol, IP y detalle JSON. Ningún rol operativo ni administrativo puede borrar la bitácora. | `trg_auditoria_manifiesto` y `trg_auditoria_contenedor` + `GRANT SELECT` exclusivo a `rol_admin` | `42501` si intenta `DELETE`/`UPDATE` | `03_triggers_inventario_y_pesos.sql`, `01_roles_y_seguridad.sql` |

---

## 2. Contrato de Procedimientos Almacenados (para Rol 1 y Aplicaciones)

### 2.1 `puerto.sp_ingresar_manifiesto`
```sql
CALL puerto.sp_ingresar_manifiesto(
    p_id_terminal            SMALLINT,     -- 1=Moín, 2=Limón, 3=Caldera
    p_numero_imo             CHAR(7),      -- Ej. '9000031'
    p_licencia_agente        VARCHAR(12),  -- Ej. 'AA-00001'
    p_numero_manifiesto      VARCHAR(20),  -- Ej. 'MAN-T1-000500'
    p_puerto_origen          VARCHAR(60),
    p_fecha_arribo           TIMESTAMPTZ,
    p_contenedores           JSONB,        -- Arreglo de contenedores + arreglo "detalles"
    p_id_manifiesto_generado BIGINT DEFAULT NULL -- INOUT: devuelve el ID generado
);
```

### 2.2 `puerto.sp_despachar_mercancia`
```sql
CALL puerto.sp_despachar_mercancia(
    p_id_contenedor          BIGINT,
    p_licencia_agente        VARCHAR(12),
    p_observaciones          TEXT DEFAULT 'Despacho aduanero autorizado',
    p_id_inspeccion_generada BIGINT DEFAULT NULL -- INOUT: devuelve el ID de InspeccionTransito
);
```

### 2.3 `puerto.sp_registrar_inspeccion` (Interfaz para `pruebas/generador_carga.py` del Rol 1)
```sql
CALL puerto.sp_registrar_inspeccion(
    p_id_terminal        SMALLINT,
    p_id_contenedor      BIGINT,
    p_id_tipo_inspeccion SMALLINT,     -- 1..5
    p_id_agente_aduanero INT,
    p_resultado          VARCHAR(12),  -- CONFORME | OBSERVACION | RETENIDO | AUTORIZADO
    p_observaciones      TEXT DEFAULT NULL
);
```
Uso directo con el generador de carga del Rol 1:
```bash
python pruebas/generador_carga.py --modo llamada \
  --llamada "CALL puerto.sp_registrar_inspeccion(%(id_terminal)s::smallint, %(id_contenedor)s, %(id_tipo_inspeccion)s::smallint, %(id_agente_aduanero)s, %(resultado)s, %(observaciones)s)"
```

---

## 3. Nota Técnica para Defensa sobre Triggers y Replicación Física

En una arquitectura con **réplica física por streaming WAL**, los nodos standby están en modo `hot_standby` (solo lectura) y **no vuelven a ejecutar funciones PL/pgSQL ni triggers**.  
Los cambios producidos por `trg_02_aplicar_efecto_inspeccion`, `trg_auditoria_*` o los procedimientos almacenados quedan grabados en los registros WAL del primario y llegan ya materializados por bloques al standby. Esto garantiza consistencia exacta entre primario y réplica sin riesgo de doble ejecución.
