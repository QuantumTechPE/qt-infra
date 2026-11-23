#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Promoción GitOps: compone el SNAPSHOT del ambiente a partir de deploy/ del
# servicio (recursos, HPA, ConfigMaps, secretos declarados) + la imagen, y lo
# escribe en qt-gitops/apps/<servicio>/<ambiente>/values.yaml. Argo CD del
# clúster de ese ambiente despliega el cambio. La configuración viaja así con la
# versión: prod recibe exactamente la del release aprobado.
#
#   gitops-promote.sh promote        → publica `revision=<sha>` en GITHUB_OUTPUT
#   gitops-promote.sh revert <sha>   → revierte ese commit (rollback GitOps)
#
# Entradas: GH_TOKEN (GitHub App, acotado al repo GitOps), GITOPS_REPO (owner/repo),
#           SERVICE, ENVIRONMENT, IMAGE, DIGEST, VERSION (opcional),
#           SERVICE_DIR (checkout del servicio en el commit que se despliega)
# Requiere: git, yq (v4), compose-values.sh (mismo directorio)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${GITOPS_REPO:?}" "${SERVICE:?}" "${ENVIRONMENT:?}"
action="${1:?promote | revert <sha>}"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(cd "${SERVICE_DIR:-.}" && pwd)"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# GITHUB_SERVER_URL lo define GitHub Actions (también sirve para GitHub Enterprise)
server="${GITHUB_SERVER_URL:-https://github.com}"
git clone --quiet --depth 50 \
  "${server%%://*}://${GIT_USERNAME:-x-access-token}:${GH_TOKEN}@${server#*://}/${GITOPS_REPO}.git" "$workdir/gitops"
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
  promote)
    : "${IMAGE:?}" "${DIGEST:?}"
    [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::Digest inválido: $DIGEST"; exit 1; }
    file="apps/${SERVICE}/${ENVIRONMENT}/values.yaml"
    if [[ ! -f "$file" ]]; then
      echo "::error::${file} no existe en ${GITOPS_REPO}: el servicio no está dado de alta (qt-infra/scripts/new-service.sh)"
      exit 1
    fi
    export IMAGE DIGEST
    export TAG="${VERSION:-sha-${GITHUB_SHA:0:7}}"
    export SOURCE="${GITHUB_REPOSITORY:-${SERVICE}}@${GITHUB_SHA:-local}"
    bash "${scripts_dir}/compose-values.sh" "$SERVICE_DIR" "$ENVIRONMENT" "$file"

    if git diff --quiet; then
      echo "${ENVIRONMENT} ya ejecuta ${DIGEST}; nada que promover."
      echo "revision=$(git rev-parse HEAD)" >>"$out"
      exit 0
    fi

    git commit --quiet -am "deploy(${SERVICE}): ${ENVIRONMENT} → ${TAG}" \
      -m "Imagen: ${IMAGE}@${DIGEST}" \
      -m "Pipeline: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}"
    push_with_retry
    revision="$(git rev-parse HEAD)"
    echo "revision=${revision}" >>"$out"
    {
      echo "### GitOps → ${ENVIRONMENT}"
      echo "- Commit: ${server}/${GITOPS_REPO}/commit/${revision}"
      echo "- Imagen: \`${IMAGE}@${DIGEST}\` (${TAG})"
    } >>"$summary"
    ;;

  revert)
    sha="${2:?sha a revertir}"
    git fetch --quiet --depth 100 origin master
    git revert --no-edit "$sha"
    push_with_retry
    echo "↩ Rollback GitOps: revertido ${sha} en ${ENVIRONMENT}" | tee -a "$summary"
    ;;

  *)
    echo "Acción desconocida: $action" >&2
    exit 2
    ;;
esac
