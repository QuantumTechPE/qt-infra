#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Valida el repo GitOps: renderiza cada clúster (config de plataforma y
# observabilidad) y cada servicio × ambiente con los charts de qt-infra y
# verifica los manifiestos con kubeconform.
#   CHART_DIR=<qt-infra>/k8s/charts gitops-validate.sh   (desde la raíz de qt-gitops)
# Requiere: helm, kubeconform, yq
# -----------------------------------------------------------------------------
set -euo pipefail

CHART_DIR="${CHART_DIR:?ruta a qt-infra/k8s/charts}"
ENVIRONMENTS=(dev cert prod)
schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
fake_digest="sha256:$(printf '0%.0s' {1..64})"
errors=0
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "✔ ${label}"
  else
    echo "::error::✖ ${label}"
    errors=$((errors + 1))
  fi
}

validate() { kubeconform -strict -summary -ignore-missing-schemas "${schemas[@]}"; }

render_cluster() {
  helm template cluster-config "$CHART_DIR/cluster-config" -f "$1" | validate
}

render_observability() {
  helm template observability "$CHART_DIR/observability" --set "environment=$1" | validate
}

# El snapshot de un servicio sin versión promovida aún no tiene imagen: se valida
# con una ficticia para revisar igual la configuración.
render_service() {
  local svc="$1" env="$2" domain="$3" file="apps/$1/$2/values.yaml" extra=()
  [[ -z "$(yq '.image.digest // ""' "$file")" ]] && extra+=(--set "image.digest=${fake_digest}")
  [[ -z "$(yq '.image.repository // ""' "$file")" ]] && extra+=(--set "image.repository=registry.invalid/${svc}")
  # Configuración del ambiente (la escribe el CICD de qt-config), igual que Argo CD
  [[ -f "apps/$1/$2/config.yaml" ]] && extra+=(-f "apps/$1/$2/config.yaml")
  helm template "$svc" "$CHART_DIR/qt-service" -f "$file" \
    --set "environment=${env}" --set "global.ingressDomain=${domain}" "${extra[@]}" | validate
}

echo "## Validación GitOps" >>"$summary"

declare -A domains
for env in "${ENVIRONMENTS[@]}"; do
  dir="clusters/${env}"
  if [[ ! -d "$dir" ]]; then
    echo "::error::Falta ${dir}"
    errors=$((errors + 1))
    continue
  fi
  domains[$env]="$(yq '.ingressDomain' "${dir}/cluster-config.values.yaml")"
  check "cluster ${env}: cluster-config" render_cluster "${dir}/cluster-config.values.yaml"
  check "cluster ${env}: observabilidad" render_observability "$env"
  check "cluster ${env}: addons" kubeconform -summary -ignore-missing-schemas "${schemas[@]}" "${dir}/addons"
done

shopt -s nullglob
for svc_dir in apps/*/; do
  svc="$(basename "$svc_dir")"
  for env in "${ENVIRONMENTS[@]}"; do
    if [[ ! -f "${svc_dir}${env}/values.yaml" ]]; then
      echo "::error::Falta ${svc_dir}${env}/values.yaml"
      errors=$((errors + 1))
      continue
    fi
    check "app ${svc} (${env})" render_service "$svc" "$env" "${domains[$env]:-example.invalid}"
  done
done

if ((errors > 0)); then
  echo "❌ ${errors} validación(es) fallida(s)" >>"$summary"
  exit 1
fi
echo "✅ Clústeres y servicios renderizan y son Kubernetes válido" >>"$summary"
