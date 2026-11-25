#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Valida la carpeta deploy/ de un microservicio: compone dev, cert y prod como lo
# hará la promoción, les suma la configuración del ambiente (qt-config) y los
# renderiza con el chart qt-service (recursos, HPA, PDB, ConfigMaps, ExternalSecret...).
#
# Configuración del ambiente, en este orden:
#   <dir>/qt-config/<env>.yaml   (las plantillas de qt-infra traen la de ejemplo)
#   CONFIG_REPO=<owner/qt-config> → rama del ambiente (pre-develop, develop, master)
# Si falta, o le falta algo de requiredConfig, es solo un AVISO: la promoción
# (DEV, congelamiento y pase) es la que frena el despliegue.
#
#   deploy-validate.sh <dir-del-servicio> <nombre> <ruta-chart-qt-service>
# Requiere: yq, helm, kubeconform (y gh si se usa CONFIG_REPO)
# -----------------------------------------------------------------------------
set -euo pipefail

svc_dir="${1:?directorio del servicio}"
svc_dir="${svc_dir%/}"
name="${2:?nombre del servicio}"
chart="${3:?ruta del chart qt-service}"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-gh.sh
source "${scripts_dir}/lib-gh.sh"
# shellcheck source=config-lib.sh
source "${scripts_dir}/config-lib.sh"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
errors=0

echo "## Plan de despliegue de ${name}" >>"$summary"
echo "| Ambiente | Réplicas | CPU req/lim | Memoria req/lim | HPA | Configuración (qt-config) | Recursos K8s |" >>"$summary"
echo "|---|---|---|---|---|---|---|" >>"$summary"

for env in "${CONFIG_ENVIRONMENTS[@]}"; do
  values="$(mktemp)"
  cfg="$(mktemp)"
  rendered="$(mktemp)"
  if ! IMAGE="registry.invalid/${name}" DIGEST="sha256:$(printf '0%.0s' {1..64})" TAG="ci" \
    bash "${scripts_dir}/compose-values.sh" "$svc_dir" "$env" "$values"; then
    echo "::error::${env}: no se pudo componer deploy/"
    errors=$((errors + 1))
    continue
  fi

  # Configuración del ambiente (qt-config)
  cfg_src=""
  cfg_values=()
  if [[ -f "${svc_dir}/qt-config/${env}.yaml" ]]; then
    cp "${svc_dir}/qt-config/${env}.yaml" "$cfg" && cfg_src="plantilla qt-config/${env}.yaml"
  elif [[ -n "${CONFIG_REPO:-}" ]] && config_fetch "$CONFIG_REPO" "$name" "$env" "$cfg"; then
    cfg_src="$(config_branch "$env"):$(config_path "$name" "$env")"
  fi
  cfg_note="⚠️ sin configuración"
  if [[ -n "$cfg_src" ]]; then
    if bash "${scripts_dir}/config-render.sh" "$cfg" "$rendered"; then
      cfg_values=(-f "$rendered")
      cfg_note="✔ ${cfg_src}"
      if ! bash "${scripts_dir}/config-check.sh" "${svc_dir}/deploy/values.yaml" "$cfg" "$env" "$name" >/dev/null 2>&1; then
        echo "::warning::${env}: a ${cfg_src} le falta algo de requiredConfig; la promoción a ${env} se frenará hasta agregarlo en qt-config."
        cfg_note="⚠️ incompleta (${cfg_src})"
      fi
    else
      echo "::error::${env}: la configuración ${cfg_src} es inválida"
      errors=$((errors + 1))
      cfg_note="❌ inválida (${cfg_src})"
    fi
  else
    echo "::warning::${env}: no hay configuración en qt-config ($(config_branch "$env"):$(config_path "$name" "$env")); se valida solo lo técnico."
  fi

  if manifests="$(helm template "$name" "$chart" -f "$values" "${cfg_values[@]}" \
    --set "environment=${env}" --set "global.ingressDomain=${env}.example.invalid" 2>&1)" &&
    kubeconform -strict -summary -ignore-missing-schemas "${schemas[@]}" <<<"$manifests"; then
    kinds="$(grep '^kind:' <<<"$manifests" | awk '{print $2}' | sort | paste -sd ',' -)"
    hpa="no"
    replicas="$(yq '.replicaCount // 1' "$values")"
    if [[ "$(yq '.autoscaling.enabled // false' "$values")" == "true" ]]; then
      hpa="$(yq '"\(.autoscaling.minReplicas)-\(.autoscaling.maxReplicas) @ \(.autoscaling.targetCPUUtilizationPercentage)% CPU"' "$values")"
      replicas="HPA"
    fi
    printf '| %s | %s | %s / %s | %s / %s | %s | %s | %s |\n' "$env" "$replicas" \
      "$(yq '.resources.requests.cpu // "-"' "$values")" "$(yq '.resources.limits.cpu // "-"' "$values")" \
      "$(yq '.resources.requests.memory // "-"' "$values")" "$(yq '.resources.limits.memory // "-"' "$values")" \
      "$hpa" "$cfg_note" "$kinds" >>"$summary"
    echo "✔ ${env}"
  else
    echo "$manifests" | tail -5
    echo "::error::${env}: deploy/ no renderiza o produce manifiestos inválidos"
    errors=$((errors + 1))
  fi
  rm -f "$values" "$cfg" "$rendered"
done

((errors == 0)) || exit 1
