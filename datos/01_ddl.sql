-- datos/01_ddl.sql | Consolidado de sql/01_ddl/ (00..04) con nomenclatura oficial
-- 00_esquema.sql | Esquema puerto y extension pgcrypto
-- Uso: psql -U postgres -d puerto -p 544N -f sql/01_ddl/00_esquema.sql
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS puerto;
SET search_path = puerto, public;

-- 01_catalogos.sql | Tablas de catalogo (iguales en los 3 nodos)
-- Nomenclatura: tablas PascalCase en singular; columnas [Prefijo]_[NombreCampo]
--   (CI entero, CT texto, CB booleano, CD decimal, CF fecha). Los identificadores van entre
--   comillas dobles porque PostgreSQL pasa a minusculas todo lo que no esta entrecomillado.
-- Restricciones: PK_Tabla | FK_TablaHija_X_TablaPadre | UQ_Tabla_Campo | CK_Tabla_Campo
\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE TABLE "Pais" (
  "CI_IdPais"    SMALLINT    NOT NULL,
  "CT_CodigoIso" CHAR(2)     NOT NULL,
  "CT_Nombre"    VARCHAR(60) NOT NULL,
  CONSTRAINT "PK_Pais" PRIMARY KEY ("CI_IdPais"),
  CONSTRAINT "UQ_Pais_CT_CodigoIso" UNIQUE ("CT_CodigoIso")
);

CREATE TABLE "TipoContenedor" (
  "CI_IdTipoContenedor" SMALLINT    NOT NULL,
  "CT_Codigo"           VARCHAR(5)  NOT NULL,
  "CT_Descripcion"      VARCHAR(60) NOT NULL,
  "CI_LongitudPies"     SMALLINT    NOT NULL,
  CONSTRAINT "PK_TipoContenedor" PRIMARY KEY ("CI_IdTipoContenedor"),
  CONSTRAINT "UQ_TipoContenedor_CT_Codigo" UNIQUE ("CT_Codigo"),
  CONSTRAINT "CK_TipoContenedor_CI_LongitudPies" CHECK ("CI_LongitudPies" IN (20,40))
);

CREATE TABLE "EstadoContenedor" (
  "CI_IdEstadoContenedor" SMALLINT    NOT NULL,
  "CT_Codigo"             VARCHAR(20) NOT NULL,
  "CT_Descripcion"        VARCHAR(80) NOT NULL,
  CONSTRAINT "PK_EstadoContenedor" PRIMARY KEY ("CI_IdEstadoContenedor"),
  CONSTRAINT "UQ_EstadoContenedor_CT_Codigo" UNIQUE ("CT_Codigo")
);

CREATE TABLE "TipoInspeccion" (
  "CI_IdTipoInspeccion" SMALLINT     NOT NULL,
  "CT_Codigo"           VARCHAR(20)  NOT NULL,
  "CT_Descripcion"      VARCHAR(100) NOT NULL,
  CONSTRAINT "PK_TipoInspeccion" PRIMARY KEY ("CI_IdTipoInspeccion"),
  CONSTRAINT "UQ_TipoInspeccion_CT_Codigo" UNIQUE ("CT_Codigo")
);

CREATE TABLE "PartidaArancelaria" (
  "CI_IdPartidaArancelaria" SMALLINT     NOT NULL,
  "CT_CodigoHs"             VARCHAR(10)  NOT NULL,
  "CT_Descripcion"          VARCHAR(100) NOT NULL,
  "CD_TasaArancelPct"       NUMERIC(5,2) NOT NULL,
  CONSTRAINT "PK_PartidaArancelaria" PRIMARY KEY ("CI_IdPartidaArancelaria"),
  CONSTRAINT "UQ_PartidaArancelaria_CT_CodigoHs" UNIQUE ("CT_CodigoHs"),
  CONSTRAINT "CK_PartidaArancelaria_CD_TasaArancelPct" CHECK ("CD_TasaArancelPct" >= 0)
);

-- 02_entidades_comunes.sql | Entidades replicadas IDENTICAS en los 3 nodos (IDs fijos, sin secuencias)
-- Nomenclatura: ver 01_catalogos.sql (PascalCase, prefijos CI/CT/CB/CD/CF, identificadores entre comillas).
\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE TABLE "TerminalMaritima" (
  "CI_IdTerminalMaritima" SMALLINT    NOT NULL,      -- 1=Moin, 2=Limon, 3=Caldera
  "CT_Codigo"             VARCHAR(5)  NOT NULL,
  "CT_Nombre"             VARCHAR(80) NOT NULL,
  "CT_Provincia"          VARCHAR(40) NOT NULL,
  CONSTRAINT "PK_TerminalMaritima" PRIMARY KEY ("CI_IdTerminalMaritima"),
  CONSTRAINT "UQ_TerminalMaritima_CT_Codigo" UNIQUE ("CT_Codigo")
);

CREATE TABLE "DependenciaAduanera" (
  "CI_IdDependenciaAduanera" SMALLINT    NOT NULL,
  "CI_IdTerminalMaritima"    SMALLINT    NOT NULL,
  "CT_Codigo"                VARCHAR(10) NOT NULL,
  "CT_Nombre"                VARCHAR(80) NOT NULL,
  CONSTRAINT "PK_DependenciaAduanera" PRIMARY KEY ("CI_IdDependenciaAduanera"),
  CONSTRAINT "UQ_DependenciaAduanera_CT_Codigo" UNIQUE ("CT_Codigo"),
  CONSTRAINT "FK_DependenciaAduanera_X_TerminalMaritima" FOREIGN KEY ("CI_IdTerminalMaritima")
    REFERENCES "TerminalMaritima" ("CI_IdTerminalMaritima") ON DELETE RESTRICT
);

CREATE TABLE "Naviera" (
  "CI_IdNaviera"      INT         NOT NULL,
  "CI_IdPais"         SMALLINT    NOT NULL,
  "CT_Nombre"         VARCHAR(80) NOT NULL,
  "CT_CedulaJuridica" VARCHAR(15) NOT NULL,
  CONSTRAINT "PK_Naviera" PRIMARY KEY ("CI_IdNaviera"),
  CONSTRAINT "UQ_Naviera_CT_CedulaJuridica" UNIQUE ("CT_CedulaJuridica"),
  CONSTRAINT "FK_Naviera_X_Pais" FOREIGN KEY ("CI_IdPais")
    REFERENCES "Pais" ("CI_IdPais") ON DELETE RESTRICT
);

CREATE TABLE "Buque" (
  "CI_IdBuque"        INT         NOT NULL,
  "CI_IdNaviera"      INT         NOT NULL,
  "CI_IdPaisBandera"  SMALLINT    NOT NULL,          -- FK con rol (bandera) hacia Pais
  "CT_Nombre"         VARCHAR(80) NOT NULL,
  "CT_NumeroImo"      CHAR(7)     NOT NULL,
  "CI_CapacidadTeu"   INT         NOT NULL,
  CONSTRAINT "PK_Buque" PRIMARY KEY ("CI_IdBuque"),
  CONSTRAINT "UQ_Buque_CT_NumeroImo" UNIQUE ("CT_NumeroImo"),
  CONSTRAINT "CK_Buque_CI_CapacidadTeu" CHECK ("CI_CapacidadTeu" > 0),
  CONSTRAINT "FK_Buque_X_Naviera" FOREIGN KEY ("CI_IdNaviera")
    REFERENCES "Naviera" ("CI_IdNaviera") ON DELETE RESTRICT,
  CONSTRAINT "FK_Buque_X_Pais" FOREIGN KEY ("CI_IdPaisBandera")
    REFERENCES "Pais" ("CI_IdPais") ON DELETE RESTRICT
);

CREATE TABLE "AgenteAduanero" (
  "CI_IdAgenteAduanero" INT          NOT NULL,
  "CT_CodigoLicencia"   VARCHAR(12)  NOT NULL,
  "CT_Nombre"           VARCHAR(60)  NOT NULL,
  "CT_Apellidos"        VARCHAR(80)  NOT NULL,
  "CT_Correo"           VARCHAR(100) NOT NULL,
  "CT_CedulaEnc"        BYTEA        NOT NULL,       -- cifrado (pgcrypto) via puerto.cifrar()
  "CT_TelefonoEnc"      BYTEA        NOT NULL,       -- cifrado (pgcrypto) via puerto.cifrar()
  "CB_Activo"           BOOLEAN      NOT NULL DEFAULT TRUE,
  CONSTRAINT "PK_AgenteAduanero" PRIMARY KEY ("CI_IdAgenteAduanero"),
  CONSTRAINT "UQ_AgenteAduanero_CT_CodigoLicencia" UNIQUE ("CT_CodigoLicencia"),
  CONSTRAINT "UQ_AgenteAduanero_CT_Correo" UNIQUE ("CT_Correo")
);

CREATE INDEX "IX_DependenciaAduanera_CI_IdTerminalMaritima" ON "DependenciaAduanera" ("CI_IdTerminalMaritima");
CREATE INDEX "IX_Buque_CI_IdNaviera" ON "Buque" ("CI_IdNaviera");

-- 03_fragmento.sql | Tablas FRAGMENTADAS: cada nodo guarda solo el subarbol de su terminal.
-- Uso (una vez por nodo):  psql -U postgres -d puerto -p 544N -v nodo=N -f 03_fragmento.sql
--   nodo 1 = Moin, 2 = Limon, 3 = Caldera.
-- 3FN: solo ManifiestoCarga lleva CI_IdTerminalMaritima; las hijas lo heredan por la cadena de FK.
-- IDs: el nodo N usa el rango [N*1e9, N*1e9 + 999999999] => unicos globalmente sin coordinacion.
-- Nomenclatura: ver 01_catalogos.sql (PascalCase, prefijos CI/CT/CB/CD/CF, identificadores entre comillas).
\set ON_ERROR_STOP on
\if :{?nodo}
\else
  \echo 'ERROR: falta -v nodo=N (1=Moin, 2=Limon, 3=Caldera)'
  \quit
\endif
SELECT (:nodo IN (1,2,3)) AS nodo_valido \gset
\if :nodo_valido
\else
  \echo 'ERROR: nodo debe ser 1, 2 o 3'
  \quit
\endif
SELECT :nodo::bigint * 1000000000 AS base, :nodo::bigint * 1000000000 + 999999999 AS tope \gset
SET search_path = puerto, public;

CREATE TABLE "ManifiestoCarga" (
  "CI_IdManifiestoCarga"  BIGINT GENERATED BY DEFAULT AS IDENTITY
        (START WITH :base MINVALUE :base MAXVALUE :tope) NOT NULL,
  "CI_IdTerminalMaritima" SMALLINT    NOT NULL,
  "CI_IdBuque"            INT         NOT NULL,
  "CI_IdAgenteAduanero"   INT         NOT NULL,
  "CT_NumeroManifiesto"   VARCHAR(20) NOT NULL,          -- formato MAN-T<nodo>-NNNNNN
  "CT_PuertoOrigen"       VARCHAR(60) NOT NULL,
  "CF_FechaArribo"        TIMESTAMPTZ NOT NULL,
  "CF_FechaRegistro"      TIMESTAMPTZ NOT NULL DEFAULT now(),
  "CT_Estado"             VARCHAR(20) NOT NULL DEFAULT 'REGISTRADO',
  CONSTRAINT "PK_ManifiestoCarga" PRIMARY KEY ("CI_IdManifiestoCarga"),
  CONSTRAINT "UQ_ManifiestoCarga_CT_NumeroManifiesto" UNIQUE ("CT_NumeroManifiesto"),
  CONSTRAINT "CK_ManifiestoCarga_Fragmento" CHECK ("CI_IdTerminalMaritima" = :nodo),
  CONSTRAINT "CK_ManifiestoCarga_CT_Estado" CHECK ("CT_Estado" IN
    ('REGISTRADO','EN_DESCARGA','EN_INSPECCION','DESPACHO_PARCIAL','CERRADO')),
  CONSTRAINT "FK_ManifiestoCarga_X_TerminalMaritima" FOREIGN KEY ("CI_IdTerminalMaritima")
    REFERENCES "TerminalMaritima" ("CI_IdTerminalMaritima") ON DELETE RESTRICT,
  CONSTRAINT "FK_ManifiestoCarga_X_Buque" FOREIGN KEY ("CI_IdBuque")
    REFERENCES "Buque" ("CI_IdBuque") ON DELETE RESTRICT,
  CONSTRAINT "FK_ManifiestoCarga_X_AgenteAduanero" FOREIGN KEY ("CI_IdAgenteAduanero")
    REFERENCES "AgenteAduanero" ("CI_IdAgenteAduanero") ON DELETE RESTRICT
);

CREATE TABLE "Contenedor" (
  "CI_IdContenedor"       BIGINT GENERATED BY DEFAULT AS IDENTITY
        (START WITH :base MINVALUE :base MAXVALUE :tope) NOT NULL,
  "CI_IdManifiestoCarga"  BIGINT        NOT NULL,
  "CI_IdTipoContenedor"   SMALLINT      NOT NULL,
  "CI_IdEstadoContenedor" SMALLINT      NOT NULL DEFAULT 1,
  "CT_NumeroIso"          CHAR(11)      NOT NULL,
  "CD_TaraKg"             NUMERIC(10,2) NOT NULL,
  "CD_PesoMaxKg"          NUMERIC(10,2) NOT NULL,      -- peso bruto maximo de la placa de ESTA unidad
  "CB_RequiereRefrigeracion" BOOLEAN    NOT NULL DEFAULT FALSE,
  "CD_TemperaturaC"       NUMERIC(4,1),
  CONSTRAINT "PK_Contenedor" PRIMARY KEY ("CI_IdContenedor"),
  CONSTRAINT "UQ_Contenedor_CT_NumeroIso" UNIQUE ("CT_NumeroIso"),
  CONSTRAINT "CK_Contenedor_CT_NumeroIso" CHECK ("CT_NumeroIso" ~ '^[A-Z]{4}[0-9]{7}$'),
  CONSTRAINT "CK_Contenedor_CD_TaraKg" CHECK ("CD_TaraKg" > 0),
  CONSTRAINT "CK_Contenedor_CD_PesoMaxKg" CHECK ("CD_PesoMaxKg" > "CD_TaraKg"),
  CONSTRAINT "CK_Contenedor_CB_RequiereRefrigeracion" CHECK (
        ("CB_RequiereRefrigeracion" AND "CD_TemperaturaC" IS NOT NULL)
     OR (NOT "CB_RequiereRefrigeracion" AND "CD_TemperaturaC" IS NULL)),
  CONSTRAINT "FK_Contenedor_X_ManifiestoCarga" FOREIGN KEY ("CI_IdManifiestoCarga")
    REFERENCES "ManifiestoCarga" ("CI_IdManifiestoCarga") ON DELETE RESTRICT,
  CONSTRAINT "FK_Contenedor_X_TipoContenedor" FOREIGN KEY ("CI_IdTipoContenedor")
    REFERENCES "TipoContenedor" ("CI_IdTipoContenedor") ON DELETE RESTRICT,
  CONSTRAINT "FK_Contenedor_X_EstadoContenedor" FOREIGN KEY ("CI_IdEstadoContenedor")
    REFERENCES "EstadoContenedor" ("CI_IdEstadoContenedor") ON DELETE RESTRICT
);

CREATE TABLE "DetalleMercancia" (
  "CI_IdDetalleMercancia"   BIGINT GENERATED BY DEFAULT AS IDENTITY
        (START WITH :base MINVALUE :base MAXVALUE :tope) NOT NULL,
  "CI_IdContenedor"         BIGINT        NOT NULL,
  "CI_IdPartidaArancelaria" SMALLINT      NOT NULL,
  "CT_Descripcion"          VARCHAR(120)  NOT NULL,
  "CI_Cantidad"             INT           NOT NULL,
  "CD_PesoKg"               NUMERIC(10,2) NOT NULL,
  "CT_ValorDeclaradoEnc"    BYTEA         NOT NULL,    -- cifrado
  "CT_ValorArancelarioEnc"  BYTEA         NOT NULL,    -- cifrado
  "CT_EstadoInventario"     VARCHAR(12)   NOT NULL DEFAULT 'DISPONIBLE',
  CONSTRAINT "PK_DetalleMercancia" PRIMARY KEY ("CI_IdDetalleMercancia"),
  CONSTRAINT "CK_DetalleMercancia_CI_Cantidad" CHECK ("CI_Cantidad" > 0),
  CONSTRAINT "CK_DetalleMercancia_CD_PesoKg" CHECK ("CD_PesoKg" > 0),
  CONSTRAINT "CK_DetalleMercancia_CT_EstadoInventario" CHECK
        ("CT_EstadoInventario" IN ('DISPONIBLE','BLOQUEADO','DESPACHADO')),
  CONSTRAINT "FK_DetalleMercancia_X_Contenedor" FOREIGN KEY ("CI_IdContenedor")
    REFERENCES "Contenedor" ("CI_IdContenedor") ON DELETE RESTRICT,
  CONSTRAINT "FK_DetalleMercancia_X_PartidaArancelaria" FOREIGN KEY ("CI_IdPartidaArancelaria")
    REFERENCES "PartidaArancelaria" ("CI_IdPartidaArancelaria") ON DELETE RESTRICT
);

CREATE TABLE "InspeccionTransito" (
  "CI_IdInspeccionTransito" BIGINT GENERATED BY DEFAULT AS IDENTITY
        (START WITH :base MINVALUE :base MAXVALUE :tope) NOT NULL,
  "CI_IdContenedor"         BIGINT       NOT NULL,
  "CI_IdTipoInspeccion"     SMALLINT     NOT NULL,
  "CI_IdAgenteAduanero"     INT,
  "CF_FechaHora"            TIMESTAMPTZ  NOT NULL DEFAULT now(),
  "CT_Resultado"            VARCHAR(12)  NOT NULL,
  "CT_Observaciones"        TEXT,
  CONSTRAINT "PK_InspeccionTransito" PRIMARY KEY ("CI_IdInspeccionTransito"),
  CONSTRAINT "CK_InspeccionTransito_CT_Resultado" CHECK
        ("CT_Resultado" IN ('CONFORME','OBSERVACION','RETENIDO','AUTORIZADO')),
  CONSTRAINT "FK_InspeccionTransito_X_Contenedor" FOREIGN KEY ("CI_IdContenedor")
    REFERENCES "Contenedor" ("CI_IdContenedor") ON DELETE RESTRICT,
  CONSTRAINT "FK_InspeccionTransito_X_TipoInspeccion" FOREIGN KEY ("CI_IdTipoInspeccion")
    REFERENCES "TipoInspeccion" ("CI_IdTipoInspeccion") ON DELETE RESTRICT,
  CONSTRAINT "FK_InspeccionTransito_X_AgenteAduanero" FOREIGN KEY ("CI_IdAgenteAduanero")
    REFERENCES "AgenteAduanero" ("CI_IdAgenteAduanero") ON DELETE RESTRICT
);

-- Indices sobre FK (PostgreSQL no los crea solo). Se justifican en pruebas/explain_indices.sql
CREATE INDEX "IX_ManifiestoCarga_CI_IdBuque"           ON "ManifiestoCarga" ("CI_IdBuque");
CREATE INDEX "IX_ManifiestoCarga_CI_IdAgenteAduanero"  ON "ManifiestoCarga" ("CI_IdAgenteAduanero");
CREATE INDEX "IX_Contenedor_CI_IdManifiestoCarga"      ON "Contenedor" ("CI_IdManifiestoCarga");
CREATE INDEX "IX_Contenedor_CI_IdEstadoContenedor"     ON "Contenedor" ("CI_IdEstadoContenedor");
CREATE INDEX "IX_DetalleMercancia_CI_IdContenedor"     ON "DetalleMercancia" ("CI_IdContenedor");
CREATE INDEX "IX_DetalleMercancia_CI_IdPartidaArancelaria" ON "DetalleMercancia" ("CI_IdPartidaArancelaria");
CREATE INDEX "IX_InspeccionTransito_CI_IdContenedor"   ON "InspeccionTransito" ("CI_IdContenedor", "CF_FechaHora" DESC);

-- 04_stub_cifrado.sql | Funciones base de cifrado (pgcrypto)
-- Permite que el DML masivo del Rol 1 y las pruebas de verificacion funcionen de inmediato.
-- El Rol 3 puede reemplazar el cuerpo de estas funciones manteniendo la firma.
\set ON_ERROR_STOP on
SET search_path = puerto, public;

CREATE OR REPLACE FUNCTION puerto.cifrar(p_texto TEXT)
RETURNS BYTEA
LANGUAGE sql AS $$
  SELECT pgp_sym_encrypt(
    p_texto,
    coalesce(current_setting('puerto.clave_cifrado', true), 'clave-solo-desarrollo')
  );
$$;

CREATE OR REPLACE FUNCTION puerto.descifrar(p_dato BYTEA)
RETURNS TEXT
LANGUAGE sql AS $$
  SELECT pgp_sym_decrypt(
    p_dato,
    coalesce(current_setting('puerto.clave_cifrado', true), 'clave-solo-desarrollo')
  );
$$;
