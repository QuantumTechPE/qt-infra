#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Valida un archivo de qt-config y lo convierte en valores del chart qt-service
# (lo que se escribe en qt-gitops/apps/<servicio>/<ambiente>/config.yaml).
#
#   config-render.sh <archivo> [salida]      (sin salida: solo valida)
#
# Formato del archivo (<ambiente>/<servicio>-<ambiente>.yaml):
#   env:      variables de entorno          → ConfigMap <servicio>-config
#   files:    archivos (nombre: contenido)  → ConfigMap <servicio>-files
#   secrets:  [{name, generate, description}] SOLO nombres; los valores están en
#             Vault secret/apps/<servicio>/<ambiente> (External Secrets)
# Requiere: yq v4
# -----------------------------------------------------------------------------
set -euo pipefail

file="${1:?archivo de qt-config}"
out="${2:-}"
[[ -f "$file" ]] || { echo "::error::No existe ${file}"; exit 1; }

errors=()
add() { errors+=("$1"); }
q() { yq -r "$1" "$file"; }

[[ "$(q 'type')" == "!!map" ]] || { echo "::error file=${file}::El archivo debe ser un mapa con env, files y secrets"; exit 1; }
extra="$(q 'keys | .[] | select(. != "env" and . != "files" and . != "secrets")' | paste -sd ',' -)"
[[ -z "$extra" ]] || add "claves no permitidas: ${extra} (solo env, files, secrets)"

if [[ "$(q '.env // {} | type')" != "!!map" ]]; then
  add "env debe ser un mapa NOMBRE: valor"
else
  bad="$(q '.env // {} | keys | .[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "env: nombres de variable inválidos: ${bad}"
  bad="$(q '.env // {} | to_entries | .[] | select(.value | type | test("^!!(str|int|float|bool)$") | not) | .key' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "env: los valores deben ser texto o número (no listas ni mapas): ${bad}"
fi

if [[ "$(q '.files // {} | type')" != "!!map" ]]; then
  add "files debe ser un mapa nombre-de-archivo: contenido"
else
  bad="$(q '.files // {} | keys | .[] | select(test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not)' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "files: nombres de archivo inválidos: ${bad}"
  bad="$(q '.files // {} | to_entries | .[] | select(.value | type != "!!str") | .key' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "files: el contenido debe ser texto (usa |): ${bad}"
fi

if [[ "$(q '.secrets // [] | type')" != "!!seq" ]]; then
  add "secrets debe ser una lista de {name, generate, description}"
else
  bad="$(q '.secrets // [] | .[] | select((.name // "") | test("^[A-Z][A-Z0-9_]*$") | not) | (.name // "(sin nombre)")' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "secrets: nombres inválidos (MAYÚSCULAS_CON_GUION_BAJO): ${bad}"
  bad="$(q '.secrets // [] | .[] | select(has("generate") and (.generate | type) != "!!bool") | .name' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "secrets: generate debe ser true o false: ${bad}"
  bad="$(q '.secrets // [] | .[] | select(has("value") or has("valor")) | .name' | paste -sd ',' -)"
  [[ -z "$bad" ]] || add "secrets: NUNCA pongas el valor aquí (va en Vault): ${bad}"
  dup="$(q '[.secrets // [] | .[].name] | group_by(.) | .[] | select(length > 1) | .[0]' | paste -sd ',' -)"
  [[ -z "$dup" ]] || add "secrets: nombres repetidos: ${dup}"
fi

if ((${#errors[@]})); then
  for e in "${errors[@]}"; do echo "::error file=${file}::${e}"; done
  exit 1
fi

[[ -n "$out" ]] || exit 0
{
  echo "# GENERADO por el CD de qt-config desde ${SOURCE:-$file}. No editar a mano:"
  echo "# la configuración del ambiente se cambia con un PR en qt-config."
  FILE="$file" yq -n '
    load(strenv(FILE)) as $c |
    {
      "config": (($c.env // {}) | with_entries(.value |= (. | tostring))),
      "configFiles": {"files": ($c.files // {})},
      "secrets": {"enabled": ((($c.secrets // []) | length) > 0)}
    }'
} >"$out"
