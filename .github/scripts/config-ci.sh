#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CI de qt-config (cada PR):
#   1. Orden de promoción: develop solo recibe PRs desde pre-develop, master solo
#      desde develop; pre-develop recibe los cambios (ramas de trabajo).
#   2. Estructura: solo <env>/<servicio>-<env>.yaml dentro de dev/, cert/ y prod/.
#   3. Cada archivo es válido (config-render.sh) y, sumado al deploy/ actual de su
#      microservicio (rama principal del repo del servicio), renderiza con el
#      chart qt-service y produce manifiestos válidos (kubeconform).
#
#   config-ci.sh <ruta-chart-qt-service>
# Entradas: GH_TOKEN, OWNER, BASE_REF, HEAD_REF, CONFIG_DIR (checkout del PR)
# Requiere: gh, yq, helm, kubeconform
# -----------------------------------------------------------------------------
set -euo pipefail
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-gh.sh
source "${scripts_dir}/lib-gh.sh"
# shellcheck source=config-lib.sh
source "${scripts_dir}/config-lib.sh"

chart="$(cd "${1:?ruta del chart qt-service}" && pwd)"
: "${GH_TOKEN:?}" "${OWNER:?}" "${BASE_REF:?}" "${HEAD_REF:?}"
CONFIG_DIR="$(cd "${CONFIG_DIR:-.}" && pwd)"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
errors=0
fail() { echo "::error${2:+ file=$2}::$1"; errors=$((errors + 1)); }

# ------------------------------------------------------------------ 1. orden de promoción
echo "## qt-config · ${HEAD_REF} → ${BASE_REF}" >>"$summary"
case "$BASE_REF" in
  develop) [[ "$HEAD_REF" == "pre-develop" ]] || fail "develop (cert) solo recibe la promoción desde pre-develop. Abre tu PR contra pre-develop." ;;
  master) [[ "$HEAD_REF" == "develop" ]] || fail "master (prod) solo recibe la promoción desde develop. Abre tu PR contra pre-develop." ;;
  pre-develop) [[ "$HEAD_REF" != "develop" && "$HEAD_REF" != "master" ]] || fail "pre-develop no recibe ramas de ambiente: los cambios suben pre-develop → develop → master." ;;
  *) fail "Los PRs de qt-config van contra pre-develop (luego se promueven a develop y master)." ;;
esac

# ------------------------------------------------------------------ 2 y 3. archivos
schemas=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
echo "| Archivo | Servicio | Resultado |" >>"$summary"
echo "|---|---|---|" >>"$summary"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$CONFIG_DIR"

while IFS= read -r f; do
  [[ "$f" == */.gitkeep ]] && continue
  if [[ ! "$f" =~ ^(dev|cert|prod)/([a-z][a-z0-9-]*[a-z0-9])-(dev|cert|prod)\.yaml$ ]] || [[ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]]; then
    fail "Nombre o ubicación inválidos: ${f}. Usa <ambiente>/<servicio>-<ambiente>.yaml (p. ej. cert/qt-pedidos-cert.yaml)." "$f"
    echo "| \`${f}\` | — | ❌ nombre/ubicación |" >>"$summary"
    continue
  fi
  env="${BASH_REMATCH[1]}"
  svc="${BASH_REMATCH[2]}"
  if ! bash "${scripts_dir}/config-render.sh" "$f" "$work/config.yaml"; then
    errors=$((errors + 1))
    echo "| \`${f}\` | ${svc} | ❌ formato |" >>"$summary"
    continue
  fi
  # deploy/ actual del servicio (rama principal de su repo)
  svc_dir="$work/${svc}"
  mkdir -p "$svc_dir/deploy"
  if ! gh api -H "Accept: application/vnd.github.raw+json" "repos/${OWNER}/${svc}/contents/deploy/values.yaml" >"$svc_dir/deploy/values.yaml" 2>/dev/null ||
    ! gh api -H "Accept: application/vnd.github.raw+json" "repos/${OWNER}/${svc}/contents/deploy/values-${env}.yaml" >"$svc_dir/deploy/values-${env}.yaml" 2>/dev/null; then
    fail "No se encontró el microservicio ${OWNER}/${svc} (deploy/values.yaml y deploy/values-${env}.yaml)." "$f"
    echo "| \`${f}\` | ${svc} | ❌ servicio inexistente |" >>"$summary"
    continue
  fi
  if ! IMAGE="registry.invalid/${svc}" DIGEST="sha256:$(printf '0%.0s' {1..64})" TAG="ci" \
    bash "${scripts_dir}/compose-values.sh" "$svc_dir" "$env" "$work/values.yaml" >/dev/null; then
    fail "No se pudo componer deploy/ de ${svc} para ${env}." "$f"
    continue
  fi
  if manifests="$(helm template "$svc" "$chart" -f "$work/values.yaml" -f "$work/config.yaml" \
    --set "environment=${env}" --set "global.ingressDomain=${env}.example.invalid" 2>&1)" &&
    kubeconform -strict -summary -ignore-missing-schemas "${schemas[@]}" <<<"$manifests" >/dev/null; then
    note="✅ válida"
    if ! bash "${scripts_dir}/config-check.sh" "$svc_dir/deploy/values.yaml" "$f" "$env" "$svc" >/dev/null 2>&1; then
      echo "::warning file=${f}::A ${f} le falta algo de lo que ${svc} declara en requiredConfig: su próximo despliegue en ${env} se frenará."
      note="⚠️ válida, pero incompleta para ${svc}"
    fi
    echo "| \`${f}\` | ${svc} | ${note} |" >>"$summary"
  else
    echo "$manifests" | tail -5
    fail "${f}: con el deploy/ de ${svc} no renderiza o produce manifiestos inválidos." "$f"
    echo "| \`${f}\` | ${svc} | ❌ no renderiza |" >>"$summary"
  fi
done < <(git ls-files -- dev cert prod)

stray="$(git ls-files | grep -vE '^(dev|cert|prod)/|^\.github/|^(README\.md|CODEOWNERS|\.gitattributes|\.gitignore|\.gitleaks\.toml)$' || true)"
[[ -z "$stray" ]] || fail "Archivos fuera de lugar (solo dev/, cert/, prod/ y .github/): $(paste -sd ' ' <<<"$stray")"

((errors == 0)) || { echo "::error::${errors} problema(s) en qt-config"; exit 1; }
echo "✅ qt-config válido" | tee -a "$summary"
