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
