#!/bin/bash
# Compara catalogos y entidades comunes entre los 3 primarios (hash del contenido). Correr desde infra/.
# Actualizado a la nomenclatura PascalCase y prefijos CI/CT/CB/CD/CF.
cd "$(dirname "$0")/.."
TABLAS="Pais TipoContenedor EstadoContenedor TipoInspeccion PartidaArancelaria TerminalMaritima DependenciaAduanera Naviera Buque"
Q=""
for t in $TABLAS; do
  Q="$Q SELECT '$t', md5(string_agg(x::text, '|' ORDER BY x::text)) FROM puerto.\"$t\" x UNION ALL"
done
Q="$Q SELECT 'AgenteAduanero', md5(string_agg(concat_ws(',', \"CI_IdAgenteAduanero\", \"CT_CodigoLicencia\", \"CT_Nombre\", \"CT_Apellidos\", \"CT_Correo\", \"CB_Activo\", puerto.descifrar(\"CT_CedulaEnc\"), puerto.descifrar(\"CT_TelefonoEnc\")), '|' ORDER BY \"CI_IdAgenteAduanero\")) FROM puerto.\"AgenteAduanero\" ORDER BY 1"

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
