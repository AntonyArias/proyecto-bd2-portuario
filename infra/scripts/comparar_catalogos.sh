#!/bin/bash
# Compara catalogos y entidades comunes entre los 3 primarios (hash del contenido). Correr desde infra/.
# En agente_aduanero compara el texto DESCIFRADO: el cifrado usa sal aleatoria y los bytes difieren entre nodos.
cd "$(dirname "$0")/.."
# --- consulta ---
TABLAS="pais tipo_contenedor estado_contenedor tipo_inspeccion partida_arancelaria terminal_maritima dependencia_aduanera naviera buque"
Q=""
for t in $TABLAS; do
  Q="$Q SELECT '$t', md5(string_agg(x::text, '|' ORDER BY x::text)) FROM puerto.$t x UNION ALL"
done
Q="$Q SELECT 'agente_aduanero', md5(string_agg(concat_ws(',', id_agente_aduanero, codigo_licencia, nombre, apellidos, correo, activo, puerto.descifrar(cedula_enc), puerto.descifrar(telefono_enc)), '|' ORDER BY id_agente_aduanero)) FROM puerto.agente_aduanero ORDER BY 1"
# --- fin consulta ---
for N in 1 2 3; do
  P=$(bash scripts/primario_actual.sh $N) || { echo "Fragmento $N sin primario vivo"; exit 1; }
  eval "R$N=\$(docker compose exec -T $P psql -U postgres -d puerto -At -F'|' -c \"\$Q\" | tr -d '\r')"
done
if [ "$R1" = "$R2" ] && [ "$R2" = "$R3" ]; then
  echo "OK: los $(echo "$R1" | wc -l) catalogos/entidades comunes son identicos en los 3 nodos"
else
  echo "DIFERENCIAS entre nodos (tabla|hash):"
  echo "--- nodo1 vs nodo2"; diff <(echo "$R1") <(echo "$R2") || true
  echo "--- nodo2 vs nodo3"; diff <(echo "$R2") <(echo "$R3") || true
  exit 1
fi
