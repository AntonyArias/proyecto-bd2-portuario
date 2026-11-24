-- 01_catalogos.sql (DML) | Catalogos fijos, IDENTICOS en los 3 nodos. No cambiar los IDs
-- (el generador y los triggers del Rol 3 dependen de ellos).
\set ON_ERROR_STOP on
SET search_path = puerto, public;
BEGIN;

INSERT INTO "Pais" ("CI_IdPais", "CT_CodigoIso", "CT_Nombre") VALUES
 (1,'CR','Costa Rica'),(2,'PA','Panama'),(3,'US','Estados Unidos'),(4,'CN','China'),
 (5,'MX','Mexico'),(6,'CO','Colombia'),(7,'DE','Alemania'),(8,'NL','Paises Bajos'),
 (9,'ES','Espana'),(10,'BR','Brasil'),(11,'CL','Chile'),(12,'LR','Liberia');

INSERT INTO "TipoContenedor" ("CI_IdTipoContenedor", "CT_Codigo", "CT_Descripcion", "CI_LongitudPies") VALUES
 (1,'20GP','Estandar 20 pies',20),(2,'40GP','Estandar 40 pies',40),(3,'40HC','High Cube 40 pies',40),
 (4,'20RF','Refrigerado 20 pies',20),(5,'40RF','Refrigerado 40 pies',40);

-- Regla de inventario: RETENIDO -> BLOQUEADO | LIBERADO -> DISPONIBLE | DESPACHADO -> DESPACHADO
INSERT INTO "EstadoContenedor" ("CI_IdEstadoContenedor", "CT_Codigo", "CT_Descripcion") VALUES
 (1,'EN_BUQUE','A bordo del buque'),(2,'DESCARGADO','Descargado al muelle'),
 (3,'EN_PATIO','Almacenado en el patio'),(4,'EN_INSPECCION','En revision documental o fisica'),
 (5,'RETENIDO','Retencion aduanera'),(6,'LIBERADO','Liberado por aduana'),
 (7,'DESPACHADO','Despachado y fuera de la terminal');

INSERT INTO "TipoInspeccion" ("CI_IdTipoInspeccion", "CT_Codigo", "CT_Descripcion") VALUES
 (1,'INGRESO','Ingreso del contenedor a la terminal'),(2,'REVISION_FISICA','Revision fisica de la mercancia'),
 (3,'RETENCION','Retencion aduanera'),(4,'LIBERACION','Liberacion aduanera'),
 (5,'DESPACHO','Despacho aduanero y salida');

-- partidas 1 y 2 = refrigeradas (el generador depende de este orden)
INSERT INTO "PartidaArancelaria"
 ("CI_IdPartidaArancelaria", "CT_CodigoHs", "CT_Descripcion", "CD_TasaArancelPct") VALUES
 (1,'080390','Bananos frescos',0),(2,'020130','Carne de bovino fresca deshuesada',15),
 (3,'090111','Cafe sin tostar',0),(4,'100630','Arroz semiblanqueado',35),
 (5,'870323','Automoviles 1500-3000 cc',30),(6,'847130','Computadoras portatiles',0),
 (7,'851712','Telefonos moviles',0),(8,'610910','Camisetas de algodon',14),
 (9,'640399','Calzado de cuero',14),(10,'300490','Medicamentos dosificados',0),
 (11,'392310','Cajas de plastico',14),(12,'940360','Muebles de madera',14),
 (13,'721049','Acero laminado galvanizado',5),(14,'252329','Cemento Portland',5),
 (15,'310210','Urea fertilizante',0),(16,'220300','Cerveza de malta',15);

COMMIT;
