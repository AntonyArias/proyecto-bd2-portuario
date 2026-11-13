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
