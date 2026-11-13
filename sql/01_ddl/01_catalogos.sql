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
