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
