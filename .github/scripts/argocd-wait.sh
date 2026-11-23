#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Espera a que Argo CD aplique una revisión de GitOps y la aplicación quede
# Synced + Healthy. Sale con error si queda Degraded o vence el tiempo.
#
# Entradas: ARGOCD_URL, ARGOCD_TOKEN (cuenta "ci", solo lectura), APP (<servicio>-<ambiente>),
#           REVISION (sha del commit GitOps), TIMEOUT (segundos, default 600)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${ARGOCD_URL:?}" "${ARGOCD_TOKEN:?}" "${APP:?}" "${REVISION:?}"
TIMEOUT="${TIMEOUT:-600}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
auth=(-H "Authorization: Bearer ${ARGOCD_TOKEN}")

get_app() { curl -fsS --max-time 15 "${auth[@]}" "${ARGOCD_URL%/}/api/v1/applications/${APP}${1:-}"; }

# Fuerza a Argo CD a leer el repo ya (sin esperar su polling de ~3 min)
get_app "?refresh=normal" >/dev/null || true

deadline=$((SECONDS + TIMEOUT))
last=""
while ((SECONDS < deadline)); do
  if app="$(get_app 2>/dev/null)"; then
    sync="$(jq -r '.status.sync.status // "Unknown"' <<<"$app")"
    health="$(jq -r '.status.health.status // "Unknown"' <<<"$app")"
    revisions=" $(jq -r '[.status.sync.revision, (.status.sync.revisions // [])[]] | map(select(. != null)) | join(" ")' <<<"$app") "
    state="sync=${sync} health=${health}"
    [[ "$state" != "$last" ]] && echo "[$(date -u +%T)] ${APP}: ${state}" && last="$state"

    if [[ "$revisions" == *" ${REVISION} "* ]]; then
      if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
        echo "### ✅ ${APP} Synced + Healthy en la revisión ${REVISION:0:7}" >>"$summary"
        exit 0
      fi
      if [[ "$health" == "Degraded" ]]; then
        echo "::error::${APP} quedó Degraded con la revisión ${REVISION:0:7}"
        jq -r '.status.resources[]? | select(.health.status == "Degraded") | "  - \(.kind)/\(.name): \(.health.message // "")"' <<<"$app" || true
        exit 1
      fi
    fi
  else
    echo "[$(date -u +%T)] Argo CD no responde en ${ARGOCD_URL}; reintento..."
  fi
  sleep 10
done

echo "::error::Timeout (${TIMEOUT}s) esperando a ${APP} en la revisión ${REVISION:0:7}"
exit 1
