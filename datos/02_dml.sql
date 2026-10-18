-- 02_dml.sql | Carga masiva reproducible. Se corre una vez por nodo, despues de 01_ddl.sql:
--   psql -U postgres -d puerto -p 5441 -v nodo=1 -f 02_dml.sql
-- (opcional) -v n_man=500  => manifiestos del nodo. Por defecto: Moin 300, Limon 150, Caldera 80.
-- Por manifiesto: 6 contenedores, 18 lineas de mercancia y 24 inspecciones.
-- Total por defecto: ~26 000 filas operativas y 12 720 inspecciones.
\set ON_ERROR_STOP on
\if :{?n_man}
\else
  SELECT (ARRAY[300,150,80])[:nodo] AS n_man \gset
\endif
SELECT format('%s::bigint', :nodo::bigint * 1000000000) AS base \gset
SET search_path = puerto, public;
SELECT setseed(0.42 + :nodo / 100.0);     -- aleatoriedad reproducible
BEGIN;

---------------- CATALOGOS (iguales en los 3 nodos; no cambiar los IDs) ----------------
INSERT INTO pais (id_pais, codigo_iso, nombre) VALUES
 (1,'CR','Costa Rica'),(2,'PA','Panama'),(3,'US','Estados Unidos'),(4,'CN','China'),
 (5,'MX','Mexico'),(6,'CO','Colombia'),(7,'DE','Alemania'),(8,'NL','Paises Bajos'),
 (9,'ES','Espana'),(10,'BR','Brasil'),(11,'CL','Chile'),(12,'LR','Liberia');

INSERT INTO tipo_contenedor (id_tipo_contenedor, codigo, descripcion, longitud_pies) VALUES
 (1,'20GP','Estandar 20 pies',20),(2,'40GP','Estandar 40 pies',40),(3,'40HC','High Cube 40 pies',40),
 (4,'20RF','Refrigerado 20 pies',20),(5,'40RF','Refrigerado 40 pies',40);

-- RETENIDO -> inventario BLOQUEADO | LIBERADO -> DISPONIBLE | DESPACHADO -> DESPACHADO
INSERT INTO estado_contenedor (id_estado_contenedor, codigo, descripcion) VALUES
 (1,'EN_BUQUE','A bordo del buque'),(2,'DESCARGADO','Descargado al muelle'),
 (3,'EN_PATIO','Almacenado en el patio'),(4,'EN_INSPECCION','En revision documental o fisica'),
 (5,'RETENIDO','Retencion aduanera'),(6,'LIBERADO','Liberado por aduana'),
 (7,'DESPACHADO','Despachado y fuera de la terminal');

INSERT INTO tipo_inspeccion (id_tipo_inspeccion, codigo, descripcion) VALUES
 (1,'INGRESO','Ingreso del contenedor a la terminal'),(2,'REVISION_FISICA','Revision fisica de la mercancia'),
 (3,'RETENCION','Retencion aduanera'),(4,'LIBERACION','Liberacion aduanera'),
 (5,'DESPACHO','Despacho aduanero y salida');

-- partidas 1 y 2 = refrigeradas (el generador depende de este orden)
INSERT INTO partida_arancelaria (id_partida_arancelaria, codigo_hs, descripcion, tasa_arancel_pct) VALUES
 (1,'080390','Bananos frescos',0),(2,'020130','Carne de bovino fresca deshuesada',15),
 (3,'090111','Cafe sin tostar',0),(4,'100630','Arroz semiblanqueado',35),
 (5,'870323','Automoviles 1500-3000 cc',30),(6,'847130','Computadoras portatiles',0),
 (7,'851712','Telefonos moviles',0),(8,'610910','Camisetas de algodon',14),
 (9,'640399','Calzado de cuero',14),(10,'300490','Medicamentos dosificados',0),
 (11,'392310','Cajas de plastico',14),(12,'940360','Muebles de madera',14),
 (13,'721049','Acero laminado galvanizado',5),(14,'252329','Cemento Portland',5),
 (15,'310210','Urea fertilizante',0),(16,'220300','Cerveza de malta',15);

---------------- ENTIDADES COMUNES (iguales en los 3 nodos) ----------------
INSERT INTO terminal_maritima (id_terminal_maritima, codigo, nombre, provincia) VALUES
 (1,'MOI','Terminal de Contenedores de Moin','Limon'),
 (2,'LIM','Puerto Limon - Muelle JAPDEVA','Limon'),
 (3,'CAL','Puerto Caldera','Puntarenas');

INSERT INTO dependencia_aduanera (id_dependencia_aduanera, id_terminal_maritima, codigo, nombre)
SELECT (t-1)*2+d, t, 'DA-T'||t||'-'||chr(64+d),
       CASE d WHEN 1 THEN 'Dependencia Aduanera Principal T'||t
                     ELSE 'Dependencia Aduanera Control Carga T'||t END
FROM generate_series(1,3) t, generate_series(1,2) d;

INSERT INTO naviera (id_naviera, id_pais, nombre, cedula_juridica)
SELECT g, 1+(g%12),
       'Naviera '||(ARRAY['Caribe','Atlantico','Pacifico','Tropical','Estrella','Delta','Horizonte',
        'Austral','Boreal','Cabo Verde','Mareas','Coral','Faro','Ancla','Brisa'])[g]||' S.A.',
       '3-101-'||lpad((500000+g*137)::text,6,'0')
FROM generate_series(1,15) g;

INSERT INTO buque (id_buque, id_naviera, id_pais_bandera, nombre, numero_imo, capacidad_teu)
SELECT g, 1+(g%15), 1+((g*5)%12),
       'MV '||(ARRAY['Aurora','Neptuno','Cordillera','Quetzal','Ceiba',
        'Pioneer','Meridian','Sirena','Tortuguero','Cahuita'])[1+(g%10)]||' '||g,
       lpad((9000000+g*31)::text,7,'0'), 2000+(g%10)*1500
FROM generate_series(1,60) g;

INSERT INTO agente_aduanero
 (id_agente_aduanero, codigo_licencia, nombre, apellidos, correo, cedula_enc, telefono_enc)
SELECT g, 'AA-'||lpad(g::text,5,'0'),
       (ARRAY['Maria','Jose','Ana','Luis','Carmen','Diego','Laura','Andres'])[1+(g%8)],
       (ARRAY['Mora','Jimenez','Vargas','Rojas','Campos','Solano','Brenes','Araya','Quesada'])[1+(g%9)]||' '||
       (ARRAY['Salas','Chaves','Leon','Soto','Cruz'])[1+(g%5)],
       'agente'||g||'@aduanas.example.cr',
       puerto.cifrar('1-'||lpad((1000+g*77)::text,4,'0')||'-'||lpad((g*13)::text,4,'0')),
       puerto.cifrar('8'||lpad((1000000+g*91)::text,7,'0'))
FROM generate_series(1,30) g;

---------------- FRAGMENTO LOCAL (solo la terminal de este nodo) ----------------
INSERT INTO manifiesto_carga
 (id_manifiesto_carga, id_terminal_maritima, id_buque, id_agente_aduanero,
  numero_manifiesto, puerto_origen, fecha_arribo, estado)
SELECT :base+g, :nodo, 1+((g*7+:nodo)%60), 1+((g*3)%30),
       'MAN-T'||:nodo||'-'||lpad(g::text,6,'0'),
       (ARRAY['Shanghai','Rotterdam','Miami','Cartagena','Colon','Veracruz','Santos','Valencia'])[1+(g%8)],
       now() - (random()*180)*interval '1 day',
       (ARRAY['REGISTRADO','EN_DESCARGA','EN_INSPECCION','DESPACHO_PARCIAL','CERRADO'])[1+(g%5)]
FROM generate_series(1,:n_man) g;

-- tipos 4 y 5 son refrigerados; estado 3 (EN_PATIO) pesa mas
INSERT INTO contenedor
 (id_contenedor, id_manifiesto_carga, id_tipo_contenedor, id_estado_contenedor, numero_iso,
  tara_kg, peso_max_kg, requiere_refrigeracion, temperatura_c)
SELECT :base+g, :base+1+(g%:n_man), t, (ARRAY[1,2,3,3,3,4,5,6,7])[1+(g%9)],
       (ARRAY['MOIU','LIMU','CALU'])[:nodo]||lpad(g::text,6,'0')||(g%10),
       CASE WHEN t IN (1,4) THEN 2200+round(random()*250) ELSE 3800+round(random()*300) END,
       CASE WHEN t IN (1,4) THEN 30480 ELSE 32500 END,
       t IN (4,5),
       CASE WHEN t IN (4,5) THEN (ARRAY[-18.0,4.0,2.0])[1+(g%3)] END
FROM (SELECT g, 1+(g%5) AS t FROM generate_series(1,:n_man*6) g) s;

-- 3 lineas por contenedor. Refrigerados -> partidas 1-2; los demas -> 3-16.
-- peso_kg <= 5200 por linea: nunca hay sobrepeso. El inventario sigue el estado del contenedor.
INSERT INTO detalle_mercancia
 (id_contenedor, id_partida_arancelaria, descripcion, cantidad, peso_kg,
  valor_declarado_enc, valor_arancelario_enc, estado_inventario)
SELECT c.id_contenedor, p.id_partida_arancelaria, p.descripcion||' lote '||s.g,
       1+(random()*500)::int, round((200+random()*5000)::numeric,2),
       puerto.cifrar(s.valor::text),
       puerto.cifrar(round(s.valor*p.tasa_arancel_pct/100,2)::text),
       CASE c.id_estado_contenedor WHEN 5 THEN 'BLOQUEADO' WHEN 7 THEN 'DESPACHADO'
            ELSE 'DISPONIBLE' END
FROM (SELECT g, round((500+random()*49500)::numeric,2) AS valor
      FROM generate_series(1,:n_man*6*3) g) s
JOIN contenedor c ON c.id_contenedor = :base+1+((s.g-1)%(:n_man*6))
JOIN partida_arancelaria p ON p.id_partida_arancelaria =
     CASE WHEN c.requiere_refrigeracion THEN 1+((s.g + s.g/(:n_man*6)) % 2)
          ELSE 3+((s.g + s.g/(:n_man*6)) % 14) END;

-- 4 inspecciones por contenedor. RETENCION -> RETENIDO; LIBERACION y DESPACHO -> AUTORIZADO.
INSERT INTO inspeccion_transito
 (id_contenedor, id_tipo_inspeccion, id_agente_aduanero, fecha_hora, resultado, observaciones)
SELECT :base+1+(g%(:n_man*6)), tipo, 1+((g*11)%30),
       now() - (random()*90)*interval '1 day',
       CASE tipo WHEN 3 THEN 'RETENIDO' WHEN 4 THEN 'AUTORIZADO' WHEN 5 THEN 'AUTORIZADO'
            ELSE (ARRAY['CONFORME','CONFORME','OBSERVACION'])[1+(g%3)] END,
       'Registro generado #'||g
FROM (SELECT g, 1+(g%5) AS tipo FROM generate_series(1,:n_man*6*4) g) s;

-- sincronizar las secuencias con los IDs explicitos
SELECT setval(pg_get_serial_sequence('manifiesto_carga','id_manifiesto_carga'),
              (SELECT max(id_manifiesto_carga) FROM manifiesto_carga));
SELECT setval(pg_get_serial_sequence('contenedor','id_contenedor'),
              (SELECT max(id_contenedor) FROM contenedor));
SELECT setval(pg_get_serial_sequence('detalle_mercancia','id_detalle_mercancia'),
              (SELECT max(id_detalle_mercancia) FROM detalle_mercancia));
SELECT setval(pg_get_serial_sequence('inspeccion_transito','id_inspeccion_transito'),
              (SELECT max(id_inspeccion_transito) FROM inspeccion_transito));
COMMIT;
ANALYZE;
