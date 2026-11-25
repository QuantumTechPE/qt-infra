#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CD de qt-config: aplica la configuración de UN ambiente en qt-gitops.
# Recorre <env>/*-<env>.yaml del checkout de qt-config, valida y renderiza cada
# archivo y escribe qt-gitops/apps/<servicio>/<env>/config.yaml. Argo CD aplica
# el cambio y los pods se reinician solos (el Deployment lleva la huella de los
# ConfigMaps). Idempotente: si nada cambió, no hay commit.
#
#   config-apply.sh apply          → GITHUB_OUTPUT: revision=<sha>, services="a b"
#   config-apply.sh revert <sha>   → revierte ese commit (rollback)
#
# Entradas: GH_TOKEN (GitHub App, acotado a qt-gitops), GITOPS_REPO (owner/repo),
#           ENVIRONMENT (dev | cert | prod), CONFIG_DIR (checkout de qt-config),
#           CONFIG_REPO y SOURCE_SHA (para la trazabilidad del commit)
# Requiere: git, yq v4, config-render.sh (mismo directorio)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${GITOPS_REPO:?}" "${ENVIRONMENT:?}"
action="${1:?apply | revert <sha>}"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${CONFIG_DIR:-.}" && pwd)"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
server="${GITHUB_SERVER_URL:-https://github.com}"
src="${SOURCE_SHA:-${GITHUB_SHA:-local}}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
git clone --quiet --depth 50 \
  "${server%%://*}://x-access-token:${GH_TOKEN}@${server#*://}/${GITOPS_REPO}.git" "$workdir/gitops"
cd "$workdir/gitops"
git config user.name "qt-platform[bot]"
git config user.email "qt-platform[bot]@users.noreply.github.com"

push_with_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if git push --quiet origin HEAD:master; then return 0; fi
    echo "Push rechazado (intento ${attempt}); rebase sobre master y reintento..."
    git pull --quiet --rebase origin master
  done
  return 1
}

case "$action" in
  apply)
    echo "## Configuración → ${ENVIRONMENT}" >>"$summary"
    echo "| Servicio | Resultado |" >>"$summary"
    echo "|---|---|" >>"$summary"
    errors=0
    shopt -s nullglob
    for f in "$CONFIG_DIR/${ENVIRONMENT}/"*-"${ENVIRONMENT}".yaml; do
      svc="$(basename "$f" "-${ENVIRONMENT}.yaml")"
      if [[ ! -d "apps/${svc}/${ENVIRONMENT}" ]]; then
        echo "::notice::${svc}: aún no está dado de alta en ${GITOPS_REPO} (apps/${svc}/${ENVIRONMENT}); se aplicará con su primera promoción."
        echo "| ${svc} | ⏳ sin alta en GitOps (se aplica al promover) |" >>"$summary"
        continue
      fi
      if SOURCE="${CONFIG_REPO:-qt-config}@${src:0:7} (${GITHUB_REF_NAME:-local}:${ENVIRONMENT}/$(basename "$f"))" \
        bash "${scripts_dir}/config-render.sh" "$f" "apps/${svc}/${ENVIRONMENT}/config.yaml"; then
        git add "apps/${svc}/${ENVIRONMENT}/config.yaml"
      else
        echo "| ${svc} | ❌ configuración inválida |" >>"$summary"
        errors=$((errors + 1))
      fi
    done
    ((errors == 0)) || { echo "::error::Hay archivos de configuración inválidos; no se aplica nada."; exit 1; }

    mapfile -t changed < <(git diff --cached --name-only | awk -F/ '{print $2}' | sort -u)
    if ((${#changed[@]} == 0)); then
      echo "Sin cambios de configuración en ${ENVIRONMENT}."
      echo "| (ninguno) | sin cambios |" >>"$summary"
      echo "revision=" >>"$out"
      echo "services=" >>"$out"
      exit 0
    fi
    git commit --quiet -m "config(${ENVIRONMENT}): ${changed[*]}" \
      -m "Origen: ${server}/${CONFIG_REPO:-qt-config}/commit/${src}" \
      -m "Pipeline: ${server}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}"
    push_with_retry
    revision="$(git rev-parse HEAD)"
    for s in "${changed[@]}"; do echo "| ${s} | ✅ actualizada |" >>"$summary"; done
    echo "- Commit GitOps: ${server}/${GITOPS_REPO}/commit/${revision}" >>"$summary"
    echo "revision=${revision}" >>"$out"
    echo "services=${changed[*]}" >>"$out"
    ;;

  revert)
    sha="${2:?sha a revertir}"
    git fetch --quiet --depth 100 origin master
    git revert --no-edit "$sha"
    push_with_retry
    echo "↩ Rollback de configuración: revertido ${sha} en ${ENVIRONMENT}" | tee -a "$summary"
    ;;

  *)
    echo "Acción desconocida: $action" >&2
    exit 2
    ;;
esac
