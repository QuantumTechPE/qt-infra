#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Plan del CD: decide el canal según la rama y aplica "sin historia no hay
# despliegue".
#
#   master          → channel=freeze  (congelamiento en CERT y pase a producción)
#   qt/<n>          → channel=dev     (solo si existe la historia abierta QT-<n>)
#   cualquier otra  → error (no se despliega)
#
# Entradas: GH_TOKEN (lectura de issues), REPO, REF_NAME, DEFAULT_BRANCH
# Salidas (GITHUB_OUTPUT): channel, code, issue
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${REF_NAME:?}" "${DEFAULT_BRANCH:?}"
EXPECTED_CHANNEL="${EXPECTED_CHANNEL:-}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [[ "$REF_NAME" == "$DEFAULT_BRANCH" ]]; then
  if [[ "$EXPECTED_CHANNEL" == "dev" ]]; then
    echo "::error::CICD DEV no corre sobre ${DEFAULT_BRANCH}: usa una rama de historia qt/<n> (${DEFAULT_BRANCH} va por CICD CERT)."
    exit 1
  fi
  echo "channel=freeze" >>"$out"
  echo "### ${DEFAULT_BRANCH} → congelamiento en CERT y pase a producción" >>"$summary"
  exit 0
fi

if [[ "$EXPECTED_CHANNEL" == "freeze" ]]; then
  echo "::error::CICD CERT solo corre sobre ${DEFAULT_BRANCH} (la rama '${REF_NAME}' va por CICD DEV)."
  exit 1
fi

code="$(code_from_branch "$REF_NAME")"
if [[ -z "$code" ]]; then
  echo "::error::La rama '${REF_NAME}' no despliega: solo ${DEFAULT_BRANCH} (CERT/PROD) y qt/<n> (DEV, rama de una historia)."
  exit 1
fi

read -r _ number title <<<"$(story_by_code "$REPO" "$code" open)" || true
if [[ -z "${number:-}" ]]; then
  echo "::error::No existe una historia abierta ${STORY_PREFIX}-${code} en ${REPO}: sin historia no hay despliegue."
  exit 1
fi

{
  echo "channel=dev"
  echo "code=${code}"
  echo "issue=${number}"
} >>"$out"
echo "### ${REF_NAME} → DEV · historia #${number} ${title}" >>"$summary"
