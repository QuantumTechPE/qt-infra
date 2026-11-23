#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Valida la carpeta deploy/ de un microservicio: compone dev, qa y prod como lo
# hará la promoción, los renderiza con el chart qt-service y valida los
# manifiestos (recursos, HPA, PDB, ConfigMaps, ExternalSecret...).
#   deploy-validate.sh <dir-del-servicio> <nombre> <ruta-chart-qt-service>
# Requiere: yq, helm, kubeconform
# -----------------------------------------------------------------------------
set -euo pipefail

svc_dir="${1:?directorio del servicio}"
name="${2:?nombre del servicio}"
chart="${3:?ruta del chart qt-service}"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
errors=0

echo "## Plan de despliegue de ${name}" >>"$summary"
echo "| Ambiente | Réplicas | CPU req/lim | Memoria req/lim | HPA | Recursos K8s |" >>"$summary"
echo "|---|---|---|---|---|---|" >>"$summary"

for env in dev qa prod; do
  values="$(mktemp)"
  if ! IMAGE="registry.invalid/${name}" DIGEST="sha256:$(printf '0%.0s' {1..64})" TAG="ci" \
    bash "${scripts_dir}/compose-values.sh" "$svc_dir" "$env" "$values"; then
    echo "::error::${env}: no se pudo componer deploy/"
    errors=$((errors + 1))
    continue
  fi
  if manifests="$(helm template "$name" "$chart" -f "$values" \
    --set "environment=${env}" --set "global.ingressDomain=${env}.example.invalid" 2>&1)" &&
    kubeconform -strict -summary -ignore-missing-schemas "${schemas[@]}" <<<"$manifests"; then
    kinds="$(grep '^kind:' <<<"$manifests" | awk '{print $2}' | sort | paste -sd ',' -)"
    hpa="no"
    replicas="$(yq '.replicaCount // 1' "$values")"
    if [[ "$(yq '.autoscaling.enabled // false' "$values")" == "true" ]]; then
      hpa="$(yq '"\(.autoscaling.minReplicas)-\(.autoscaling.maxReplicas) @ \(.autoscaling.targetCPUUtilizationPercentage)% CPU"' "$values")"
      replicas="HPA"
    fi
    printf '| %s | %s | %s / %s | %s / %s | %s | %s |\n' "$env" "$replicas" \
      "$(yq '.resources.requests.cpu // "-"' "$values")" "$(yq '.resources.limits.cpu // "-"' "$values")" \
      "$(yq '.resources.requests.memory // "-"' "$values")" "$(yq '.resources.limits.memory // "-"' "$values")" \
      "$hpa" "$kinds" >>"$summary"
    echo "✔ ${env}"
  else
    echo "$manifests" | tail -5
    echo "::error::${env}: deploy/ no renderiza o produce manifiestos inválidos"
    errors=$((errors + 1))
  fi
  rm -f "$values"
done

((errors == 0)) || exit 1
