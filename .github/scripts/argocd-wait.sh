#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Espera a que Argo CD aplique una revisión de GitOps y la aplicación quede
# Synced + Healthy. Sale con error si queda Degraded de forma sostenida o vence
# el tiempo.
#
# Un Degraded en los primeros instantes suele ser pasajero: el HPA recién creado
# aún no tiene métricas del pod nuevo ("unable to get metrics") o el Deployment
# todavía no existe. Solo cuenta como fallo si dura más de DEGRADED_GRACE.
#
# Entradas: ARGOCD_URL, ARGOCD_TOKEN (cuenta "ci", solo lectura), APP (<servicio>-<ambiente>),
#           REVISION (sha del commit GitOps), TIMEOUT (segundos, default 600),
#           DEGRADED_GRACE (segundos, default 180)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${ARGOCD_URL:?}" "${ARGOCD_TOKEN:?}" "${APP:?}" "${REVISION:?}"
TIMEOUT="${TIMEOUT:-600}"
DEGRADED_GRACE="${DEGRADED_GRACE:-180}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
auth=(-H "Authorization: Bearer ${ARGOCD_TOKEN}")

get_app() { curl -fsS --max-time 15 "${auth[@]}" "${ARGOCD_URL%/}/api/v1/applications/${APP}${1:-}"; }

# Fuerza a Argo CD a leer el repo ya (sin esperar su polling de ~3 min)
get_app "?refresh=normal" >/dev/null || true

deadline=$((SECONDS + TIMEOUT))
last=""
degraded_since=""
degraded_resources() {
  jq -r '.status.resources[]? | select(.health.status == "Degraded") | "  - \(.kind)/\(.name): \(.health.message // "")"' <<<"$1" || true
}

# Diagnóstico para el dev cuando el despliegue falla (sin acceso al clúster):
# estado de la app, recursos no sanos y, de los pods nuevos que no están listos,
# sus eventos de advertencia (p. ej. "Readiness probe failed: ... 404") y las
# últimas líneas de log. Va al log del job y al resumen del run.
diagnose() {
  local app tree pods ns name uid events logs
  app="$(get_app 2>/dev/null || echo '{}')"
  tree="$(get_app /resource-tree 2>/dev/null || echo '{}')"
  {
    echo "### 🩺 Diagnóstico de ${APP} (revisión ${REVISION:0:7})"
    echo "**Estado:** sync=$(jq -r '.status.sync.status // "?"' <<<"$app") · health=$(jq -r '.status.health.status // "?"' <<<"$app")"
    jq -r '.status.conditions[]? | "- **\(.type)**: \(.message)"' <<<"$app" 2>/dev/null || true
    echo
    echo "**Recursos no sanos**"
    jq -r '[.status.resources[]? | select(.health.status != null and .health.status != "Healthy")
      | "- `\(.kind)/\(.name)`: **\(.health.status)** \(.health.message // "")"] | if length == 0 then "- (ninguno informado)" else .[] end' <<<"$app" 2>/dev/null || true
    # Pods que no están listos, los más nuevos primero (son los de la versión que falla)
    pods="$(jq -c '[.nodes[]? | select(.kind == "Pod" and (.health.status // "") != "Healthy")]
      | sort_by(.createdAt) | reverse | .[:2][]' <<<"$tree" 2>/dev/null || true)"
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      ns="$(jq -r '.namespace' <<<"$pod")"
      name="$(jq -r '.name' <<<"$pod")"
      uid="$(jq -r '.uid' <<<"$pod")"
      echo
      echo "**Pod \`${name}\`** · $(jq -r '[.info[]? | "\(.name): \(.value)"] | join(" · ")' <<<"$pod")"
      events="$(get_app "/events?resourceNamespace=${ns}&resourceName=${name}&resourceUID=${uid}" 2>/dev/null |
        jq -r '[.items[]? | select(.type == "Warning") | "- \(.reason): \(.message) (×\(.count // 1))"] | unique | .[-5:][]' 2>/dev/null || true)"
      echo "Eventos:"
      echo "${events:-- (sin advertencias)}"
      logs="$(get_app "/logs?namespace=${ns}&podName=${name}&tailLines=25&follow=false" 2>/dev/null |
        jq -r '.result.content // empty' 2>/dev/null | tail -n 25 || true)"
      echo "Últimas líneas de log:"
      printf '```\n%s\n```\n' "${logs:-(sin logs o sin permiso de lectura de logs)}"
    done <<<"$pods"
  } | tee -a "$summary"
}
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
        if [[ -z "$degraded_since" ]]; then
          degraded_since=$SECONDS
          echo "[$(date -u +%T)] Degraded: espero hasta ${DEGRADED_GRACE}s por si es pasajero"
          degraded_resources "$app"
        elif ((SECONDS - degraded_since >= DEGRADED_GRACE)); then
          echo "::error::${APP} sigue Degraded tras ${DEGRADED_GRACE}s con la revisión ${REVISION:0:7}"
          diagnose
          exit 1
        fi
      else
        degraded_since=""
      fi
    fi
  else
    echo "[$(date -u +%T)] Argo CD no responde en ${ARGOCD_URL}; reintento..."
  fi
  sleep 10
done

echo "::error::Timeout (${TIMEOUT}s) esperando a ${APP} en la revisión ${REVISION:0:7}"
diagnose
exit 1
