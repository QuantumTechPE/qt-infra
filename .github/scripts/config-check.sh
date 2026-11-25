#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Verifica que la configuración del ambiente (qt-config) tenga lo que ESTA
# versión del servicio declara como obligatorio en deploy/values.yaml:
#
#   requiredConfig:
#     env: [NOMBRE, ...]        variables en env:
#     files: [archivo, ...]     archivos en files:
#     secrets: [NOMBRE, ...]    claves declaradas en secrets:
#
# Lo corren DEV (push a qt/<n>), el congelamiento (cert) y el pase (prod) ANTES
# de desplegar: si falta algo, se frena con un mensaje claro en vez de desplegar
# una versión que no arrancaría.
#
#   config-check.sh <deploy/values.yaml> <archivo-qt-config> <ambiente> <servicio>
# Requiere: yq v4
# -----------------------------------------------------------------------------
set -euo pipefail

values="${1:?deploy/values.yaml}"
config="${2:?archivo de qt-config}"
env="${3:?ambiente}"
svc="${4:?servicio}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

missing=()
check() { # check <sección> <expresión-de-lo-presente>
  local section="$1" present="$2" item
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if ! yq -e "${present} | any_c(. == \"${item}\")" "$config" >/dev/null 2>&1; then
      missing+=("${section}.${item}")
    fi
  done < <(yq -r "(.requiredConfig.${section} // [])[]" "$values")
}
check env '(.env // {}) | keys'
check files '(.files // {}) | keys'
check secrets '[(.secrets // [])[].name]'

if ((${#missing[@]})); then
  echo "::error::Falta configuración de ${svc} en ${env} (qt-config): ${missing[*]}. Agrégala con un PR en qt-config antes de desplegar."
  {
    echo "### ❌ Configuración incompleta en qt-config (${env})"
    for m in "${missing[@]}"; do echo "- \`${m}\`"; done
  } >>"$summary"
  exit 1
fi
echo "✔ ${svc} (${env}): qt-config tiene lo que esta versión necesita"
