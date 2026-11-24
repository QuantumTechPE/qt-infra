#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Carriles DEV de una historia (lo llama el CD de la rama qt/<n>):
#
#   story-board.sh start              → Despliegue DEV
#   story-board.sh result <resultado> → success: Pruebas DEV · otro: In Progress
#
# Solo mueve la historia si está en la fase DEV (DEV_LANES): un push a una rama
# cuya historia ya está en QA o en el pase no la saca de ahí.
#
# Entradas: GH_TOKEN (GitHub App), REPO, ISSUE, PROJECT_OWNER, PROJECT_NUMBER,
#           GITHUB_SHA, GITHUB_RUN_ID
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${ISSUE:?}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}"

load_project
node="$(issue_node "$REPO" "$ISSUE")"
current="$(current_status "$node")"
if ! in_list "$current" "${DEV_LANES[@]}"; then
  echo "- #${ISSUE} está en '${current}': el despliegue en DEV no la mueve." | tee -a "$summary"
  exit 0
fi

case "${1:?start | result <resultado>}" in
  start)
    set_status "$node" "Despliegue DEV"
    lane="Despliegue DEV"
    ;;
  result)
    if [[ "${2:-}" == "success" ]]; then
      set_status "$node" "Pruebas DEV"
      set_text "$node" "Versión" "dev · sha-${GITHUB_SHA:0:7}"
      lane="Pruebas DEV"
      comment "$REPO" "$ISSUE" "🧪 **En DEV** (sha-${GITHUB_SHA:0:7}): lista para **Pruebas DEV**. Si no pasa, comenta \`/rechazar <motivo>\`."
    else
      set_status "$node" "In Progress"
      lane="In Progress"
      comment "$REPO" "$ISSUE" "❌ Falló el despliegue en DEV (sha-${GITHUB_SHA:0:7}): ${run_url}"
    fi
    ;;
esac
echo "- #${ISSUE} → **${lane}**" | tee -a "$summary"
