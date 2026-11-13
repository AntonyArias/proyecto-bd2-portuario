-- datos/02_dml.sql | Consolidado de sql/02_dml/ (01..03) con nomenclatura oficial
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

-- 02_entidades_comunes.sql (DML) | Entidades comunes, IDENTICAS en los 3 nodos.
-- Orden: terminales -> dependencias -> navieras -> buques -> agentes.
-- Requiere puerto.cifrar() (04_stub_cifrado.sql o la version del Rol 3).
-- Nota: pgp_sym_encrypt no es determinista: el texto plano es igual en los 3 nodos,
-- pero los bytes cifrados de AgenteAduanero difieren entre nodos.
\set ON_ERROR_STOP on
SET search_path = puerto, public;
BEGIN;

INSERT INTO "TerminalMaritima" ("CI_IdTerminalMaritima", "CT_Codigo", "CT_Nombre", "CT_Provincia") VALUES
 (1,'MOI','Terminal de Contenedores de Moin','Limon'),
 (2,'LIM','Puerto Limon - Muelle JAPDEVA','Limon'),
 (3,'CAL','Puerto Caldera','Puntarenas');

-- 2 dependencias por terminal: ids 1-2 (Moin), 3-4 (Limon), 5-6 (Caldera)
INSERT INTO "DependenciaAduanera"
 ("CI_IdDependenciaAduanera", "CI_IdTerminalMaritima", "CT_Codigo", "CT_Nombre")
SELECT (t-1)*2+d, t, 'DA-T'||t||'-'||chr(64+d),
       CASE d WHEN 1 THEN 'Dependencia Aduanera Principal T'||t
                     ELSE 'Dependencia Aduanera Control Carga T'||t END
FROM generate_series(1,3) t, generate_series(1,2) d;

INSERT INTO "Naviera" ("CI_IdNaviera", "CI_IdPais", "CT_Nombre", "CT_CedulaJuridica")
SELECT g, 1+(g%12),
       'Naviera '||(ARRAY['Caribe','Atlantico','Pacifico','Tropical','Estrella','Delta','Horizonte',
        'Austral','Boreal','Cabo Verde','Mareas','Coral','Faro','Ancla','Brisa'])[g]||' S.A.',
       '3-101-'||lpad((500000+g*137)::text,6,'0')
FROM generate_series(1,15) g;

INSERT INTO "Buque"
 ("CI_IdBuque", "CI_IdNaviera", "CI_IdPaisBandera", "CT_Nombre", "CT_NumeroImo", "CI_CapacidadTeu")
SELECT g, 1+(g%15), 1+((g*5)%12),
       'MV '||(ARRAY['Aurora','Neptuno','Cordillera','Quetzal','Ceiba',
        'Pioneer','Meridian','Sirena','Tortuguero','Cahuita'])[1+(g%10)]||' '||g,
       lpad((9000000+g*31)::text,7,'0'), 2000+(g%10)*1500
FROM generate_series(1,60) g;

INSERT INTO "AgenteAduanero"
 ("CI_IdAgenteAduanero", "CT_CodigoLicencia", "CT_Nombre", "CT_Apellidos", "CT_Correo",
  "CT_CedulaEnc", "CT_TelefonoEnc")
SELECT g, 'AA-'||lpad(g::text,5,'0'),
       (ARRAY['Maria','Jose','Ana','Luis','Carmen','Diego','Laura','Andres'])[1+(g%8)],
       (ARRAY['Mora','Jimenez','Vargas','Rojas','Campos','Solano','Brenes','Araya','Quesada'])[1+(g%9)]||' '||
       (ARRAY['Salas','Chaves','Leon','Soto','Cruz'])[1+(g%5)],
       'agente'||g||'@aduanas.example.cr',
       puerto.cifrar('1-'||lpad((1000+g*77)::text,4,'0')||'-'||lpad((g*13)::text,4,'0')),
       puerto.cifrar('8'||lpad((1000000+g*91)::text,7,'0'))
FROM generate_series(1,30) g;

COMMIT;

-- 03_fragmento.sql (DML) | Generador de carga del fragmento local, reproducible por nodo.
-- Uso: psql -U postgres -d puerto -p 544N -v nodo=N -f 03_fragmento.sql
--      (opcional) -v n_man=500   => manifiestos del nodo.
-- Reparto por defecto (desigual): Moin 300, Limon 150, Caldera 80 manifiestos.
-- Por manifiesto: 6 contenedores, 18 lineas de mercancia y 24 inspecciones.
-- Total por defecto: 25 970 filas operativas (manifiestos+contenedores+detalles+inspecciones)
-- y 12 720 inspecciones.
\set ON_ERROR_STOP on
\if :{?nodo}
\else
  \echo 'ERROR: falta -v nodo=N'
  \quit
\endif
\if :{?n_man}
\else
  SELECT (ARRAY[300,150,80])[:nodo] AS n_man \gset
\endif
-- base tipada como bigint para que :base+g nunca desborde int4
SELECT format('%s::bigint', :nodo::bigint * 1000000000) AS base \gset
SET search_path = puerto, public;
SELECT setseed(0.42 + :nodo / 100.0);     -- aleatoriedad reproducible
BEGIN;

---------------- MANIFIESTOS ----------------
INSERT INTO "ManifiestoCarga"
 ("CI_IdManifiestoCarga", "CI_IdTerminalMaritima", "CI_IdBuque", "CI_IdAgenteAduanero",
  "CT_NumeroManifiesto", "CT_PuertoOrigen", "CF_FechaArribo", "CT_Estado")
SELECT :base+g, :nodo, 1+((g*7+:nodo)%60), 1+((g*3)%30),
       'MAN-T'||:nodo||'-'||lpad(g::text,6,'0'),
       (ARRAY['Shanghai','Rotterdam','Miami','Cartagena','Colon','Veracruz','Santos','Valencia'])[1+(g%8)],
       now() - (random()*180)*interval '1 day',
       (ARRAY['REGISTRADO','EN_DESCARGA','EN_INSPECCION','DESPACHO_PARCIAL','CERRADO'])[1+(g%5)]
FROM generate_series(1,:n_man) g;

---------------- CONTENEDORES (6 por manifiesto) ----------------
-- tipos 4 y 5 son refrigerados; el estado 3 (EN_PATIO) pesa mas en el reparto
INSERT INTO "Contenedor"
 ("CI_IdContenedor", "CI_IdManifiestoCarga", "CI_IdTipoContenedor", "CI_IdEstadoContenedor",
  "CT_NumeroIso", "CD_TaraKg", "CD_PesoMaxKg", "CB_RequiereRefrigeracion", "CD_TemperaturaC")
SELECT :base+g, :base+1+(g%:n_man), t, (ARRAY[1,2,3,3,3,4,5,6,7])[1+(g%9)],
       (ARRAY['MOIU','LIMU','CALU'])[:nodo]||lpad(g::text,6,'0')||(g%10),
       CASE WHEN t IN (1,4) THEN 2200+round(random()*250) ELSE 3800+round(random()*300) END,
       CASE WHEN t IN (1,4) THEN 30480 ELSE 32500 END,
       t IN (4,5),
       CASE WHEN t IN (4,5) THEN (ARRAY[-18.0,4.0,2.0])[1+(g%3)] END
FROM (SELECT g, 1+(g%5) AS t FROM generate_series(1,:n_man*6) g) s;

---------------- DETALLE DE MERCANCIA (3 lineas por contenedor) ----------------
-- Refrigerados -> partidas 1-2 (bananos, carne); los demas -> partidas 3-16.
-- CD_PesoKg <= 5200 por linea => max 15 600 kg por contenedor: nunca hay sobrepeso.
-- El estado del inventario sigue el del contenedor (RETENIDO->BLOQUEADO, DESPACHADO->DESPACHADO).
INSERT INTO "DetalleMercancia"
 ("CI_IdContenedor", "CI_IdPartidaArancelaria", "CT_Descripcion", "CI_Cantidad", "CD_PesoKg",
  "CT_ValorDeclaradoEnc", "CT_ValorArancelarioEnc", "CT_EstadoInventario")
SELECT c."CI_IdContenedor", p."CI_IdPartidaArancelaria", p."CT_Descripcion"||' lote '||s.g,
       1+(random()*500)::int, round((200+random()*5000)::numeric,2),
       puerto.cifrar(s.valor::text),
       puerto.cifrar(round(s.valor*p."CD_TasaArancelPct"/100,2)::text),
       CASE c."CI_IdEstadoContenedor" WHEN 5 THEN 'BLOQUEADO' WHEN 7 THEN 'DESPACHADO'
            ELSE 'DISPONIBLE' END
FROM (SELECT g, round((500+random()*49500)::numeric,2) AS valor
      FROM generate_series(1,:n_man*6*3) g) s
JOIN "Contenedor" c ON c."CI_IdContenedor" = :base+1+((s.g-1)%(:n_man*6))
JOIN "PartidaArancelaria" p ON p."CI_IdPartidaArancelaria" =
     CASE WHEN c."CB_RequiereRefrigeracion" THEN 1+((s.g + s.g/(:n_man*6)) % 2)
          ELSE 3+((s.g + s.g/(:n_man*6)) % 14) END;

---------------- INSPECCIONES (4 por contenedor) ----------------
-- RETENCION -> RETENIDO; LIBERACION y DESPACHO -> AUTORIZADO; el resto CONFORME/OBSERVACION.
INSERT INTO "InspeccionTransito"
 ("CI_IdContenedor", "CI_IdTipoInspeccion", "CI_IdAgenteAduanero", "CF_FechaHora",
  "CT_Resultado", "CT_Observaciones")
SELECT :base+1+(g%(:n_man*6)), tipo, 1+((g*11)%30),
       now() - (random()*90)*interval '1 day',
       CASE tipo WHEN 3 THEN 'RETENIDO' WHEN 4 THEN 'AUTORIZADO' WHEN 5 THEN 'AUTORIZADO'
            ELSE (ARRAY['CONFORME','CONFORME','OBSERVACION'])[1+(g%3)] END,
       'Registro generado #'||g
FROM (SELECT g, 1+(g%5) AS tipo FROM generate_series(1,:n_man*6*4) g) s;

---------------- sincronizar secuencias con los IDs explicitos ----------------
-- 1.er argumento: nombre de tabla (se interpreta como identificador: va entrecomillado).
-- 2.o argumento: nombre de columna (se toma literal, respeta mayusculas).
SELECT setval(pg_get_serial_sequence('"ManifiestoCarga"','CI_IdManifiestoCarga'),
              (SELECT max("CI_IdManifiestoCarga") FROM "ManifiestoCarga"));
SELECT setval(pg_get_serial_sequence('"Contenedor"','CI_IdContenedor'),
              (SELECT max("CI_IdContenedor") FROM "Contenedor"));
SELECT setval(pg_get_serial_sequence('"DetalleMercancia"','CI_IdDetalleMercancia'),
              (SELECT max("CI_IdDetalleMercancia") FROM "DetalleMercancia"));
SELECT setval(pg_get_serial_sequence('"InspeccionTransito"','CI_IdInspeccionTransito'),
              (SELECT max("CI_IdInspeccionTransito") FROM "InspeccionTransito"));
COMMIT;
ANALYZE;
