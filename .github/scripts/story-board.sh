#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CICD DEV: estado del commit y carriles DEV de la historia.
#
#   story-board.sh start              → status deploy/dev=pending · Despliegue DEV
#   story-board.sh result <resultado> → success: deploy/dev=success · Pruebas DEV
#                                       otro:    deploy/dev=failure · In Progress
#
# El status "deploy/dev" (firmado por la GitHub App) es un check requerido para
# mergear a master: el PR solo se mergea si su ÚLTIMO commit se desplegó en DEV y
# quedó Healthy. Un push nuevo, o "/rechazar" en pruebas DEV, lo vuelve a exigir.
#
# Los carriles solo se mueven si la historia está en la fase DEV (DEV_LANES): un
# push a una rama cuya historia ya está en QA o en el pase no la saca de ahí.
#
# Entradas: GH_TOKEN (GitHub App), REPO, ISSUE, PROJECT_OWNER, PROJECT_NUMBER,
#           GITHUB_SHA, GITHUB_RUN_ID
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${ISSUE:?}" "${GITHUB_SHA:?}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}"
short="sha-${GITHUB_SHA:0:7}"

deploy_status() {
  gh api -X POST "repos/${REPO}/statuses/${GITHUB_SHA}" -f state="$1" -f context="deploy/dev" \
    -f description="${2:0:140}" -f target_url="$run_url" >/dev/null
  echo "- Status deploy/dev=$1 en ${short}" | tee -a "$summary"
}

mode="${1:?start | result <resultado>}"
case "$mode" in
  start) deploy_status pending "Desplegando ${short} en DEV" ;;
  result)
    if [[ "${2:-}" == "success" ]]; then
      deploy_status success "Desplegado en DEV y Healthy (${short})"
    else
      deploy_status failure "Falló el despliegue en DEV (${short}): corrige y vuelve a hacer push"
    fi
    ;;
esac

load_project
node="$(issue_node "$REPO" "$ISSUE")"
current="$(current_status "$node")"
if ! in_list "$current" "${DEV_LANES[@]}"; then
  echo "- #${ISSUE} está en '${current}': el despliegue en DEV no la mueve." | tee -a "$summary"
  exit 0
fi

case "$mode" in
  start)
    set_status "$node" "Despliegue DEV"
    lane="Despliegue DEV"
    ;;
  result)
    if [[ "${2:-}" == "success" ]]; then
      set_status "$node" "Pruebas DEV"
      set_text "$node" "Versión" "dev · ${short}"
      lane="Pruebas DEV"
      comment "$REPO" "$ISSUE" "🧪 **En DEV** (${short}): lista para **Pruebas DEV**. Si no pasa, comenta \`/rechazar <motivo>\`."
    else
      set_status "$node" "In Progress"
      lane="In Progress"
      comment "$REPO" "$ISSUE" "❌ Falló el despliegue en DEV (${short}): ${run_url}"
    fi
    ;;
esac
echo "- #${ISSUE} → **${lane}**" | tee -a "$summary"
