#!/usr/bin/env bash
# =============================================================================
# Crea un microservicio nuevo con todo lo corporativo:
#
#   1. Repo público <org>/<nombre> desde la plantilla (backend Quarkus o frontend
#      Angular): esqueleto vacío + deploy/ (properties y ConfigMaps por ambiente,
#      plan de recursos, HPA, secretos de Vault) + pipelines conectados a qt-infra
#   2. Repo protegido: rulesets, environments dev/qa/prod (prod con aprobación
#      de admins), seguridad, labels, tablero de la organización
#   3. Vault: secret/apps/<nombre>/{dev,qa,prod} según deploy/vault/secrets.yaml
#   4. GitOps: PR en qt-gitops que da de alta apps/<nombre>/{dev,qa,prod}
#
# Dos formas de ejecutarlo:
#   - Workflow "Nuevo microservicio" de qt-infra (recomendado; con aprobación de admins)
#   - Local (Git Bash, raíz de qt-infra, plataforma arriba):
#       bash scripts/new-service.sh <nombre> <backend|frontend> [--api-path /api/pedidos] [--dir <carpeta>]
#
# Ejemplos:
#   bash scripts/new-service.sh qt-backend backend                  # API en /api
#   bash scripts/new-service.sh qt-pedidos backend --api-path /api/pedidos
#   bash scripts/new-service.sh qt-frontend frontend                # SPA en /
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# shellcheck source=../platform/scripts/lib-github.sh
source platform/scripts/lib-github.sh

# ------------------------------------------------------------------ argumentos
usage="uso: scripts/new-service.sh <nombre> <backend|frontend> [--api-path /api/x] [--dir carpeta] [--description texto] [--ci]"
name="${1:-}"
type="${2:-}"
shift 2 || die "$usage"
api_path=""
dest=""
description=""
ci_mode=false
while (($#)); do
  case "$1" in
    --api-path) api_path="${2:-}"; shift 2 ;;
    --dir) dest="${2:?}"; shift 2 ;;
    --description) description="${2:-}"; shift 2 ;;
    --ci) ci_mode=true; shift ;;
    *) die "Opción desconocida: $1. ${usage}" ;;
  esac
done

# ------------------------------------------------------------------ contexto
if [[ "$ci_mode" == true ]]; then
  # En el workflow: todo llega por variables (org vars + Vault + token de la GitHub App)
  : "${GH_TOKEN:?}" "${GITHUB_OWNER:?}" "${GOVERNANCE_APP_ID:?}" "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
  git config --global user.name "qt-platform[bot]"
  git config --global user.email "qt-platform[bot]@users.noreply.github.com"
else
  [[ -f platform/.env ]] || die "Falta platform/.env (ejecuta primero: platform/qt.ps1 up)"
  set -a
  # shellcheck disable=SC1091
  source platform/.env
  set +a
  command -v gh >/dev/null || die "Instala GitHub CLI: winget install GitHub.cli"
  gh auth status >/dev/null 2>&1 || die "Autentícate: gh auth login -s admin:org,project,workflow"
fi
OWNER="${GITHUB_OWNER:?}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
GITOPS_REPO="${GITOPS_REPO:-qt-gitops}"
: "${GOVERNANCE_APP_ID:?Define GOVERNANCE_APP_ID}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
output="${GITHUB_OUTPUT:-/dev/null}"

[[ "$name" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "Nombre inválido '${name}': minúsculas, números y guiones (3-40)"
[[ "$name" != "$INFRA_REPO" && "$name" != "$GITOPS_REPO" && "$name" != ".github" ]] || die "Nombre reservado: ${name}"
case "$type" in
  backend | quarkus)
    stack=quarkus
    langs='["java-kotlin","actions"]'
    api_path="${api_path:-/api}"
    ;;
  frontend | angular)
    stack=angular
    langs='["javascript-typescript","actions"]'
    [[ -z "$api_path" || "$api_path" == "/" ]] || die "Un frontend se publica en la raíz (/): no uses --api-path"
    api_path="/"
    ;;
  *) die "Tipo inválido '${type}': backend | frontend" ;;
esac
[[ "$api_path" =~ ^/[a-z0-9/_-]*$ ]] || die "--api-path inválido: ${api_path}"
dest="${dest:-$(dirname "$root")/${name}}"
description="${description:-Microservicio ${name} (${type})}"

[[ ! -e "$dest" ]] || die "Ya existe ${dest}"
! gh repo view "${OWNER}/${name}" >/dev/null 2>&1 || die "Ya existe el repo ${OWNER}/${name}"
PROJECT_NUMBER="$(gh variable get PROJECT_NUMBER --org "$OWNER" 2>/dev/null || true)"
export PROJECT_NUMBER # lo usa configure_repo

# URL git autenticada: token de la App en CI; credenciales de gh en local
git_url() {
  if [[ "$ci_mode" == true ]]; then
    echo "https://x-access-token:${GH_TOKEN}@github.com/$1.git"
  else
    echo "https://github.com/$1.git"
  fi
}

# ------------------------------------------------------------------ 1. scaffold
info "Generando ${name} (${type}: ${stack}) en ${dest}"
mkdir -p "$dest"
cp -r templates/_common/. "$dest/"
(cd "templates/service-${stack}" &&
  tar --exclude=node_modules --exclude=target --exclude=dist --exclude=coverage \
    --exclude=.angular -cf - .) | (cd "$dest" && tar -xf -)

# Tokens de la plataforma (lista explícita: no confundir con variables propias de
# otras herramientas, como __MVNW_CMD__ en mvnw.cmd)
tokens='qt-template-(quarkus|angular)|__(GITHUB_OWNER|INFRA_REPO|STACK|CODEQL_LANGUAGES)__'
grep -rlIE "$tokens" "$dest" | xargs sed -i \
  -e "s|qt-template-${stack}|${name}|g" \
  -e "s|__GITHUB_OWNER__|${OWNER}|g" \
  -e "s|__INFRA_REPO__|${INFRA_REPO}|g" \
  -e "s|__STACK__|${stack}|g" \
  -e "s|__CODEQL_LANGUAGES__|${langs}|g"
if [[ "$stack" == "quarkus" ]]; then
  # La ruta pública es la misma en el código (build) y en el Ingress (deploy/)
  sed -i "s|^quarkus.http.root-path=.*|quarkus.http.root-path=${api_path}|" "$dest/src/main/resources/application.properties"
  sed -i "s|^  path: /api$|  path: ${api_path}|" "$dest/deploy/values.yaml"
fi
if grep -rnIE "$tokens" "$dest"; then die "Quedaron tokens sin reemplazar"; fi
ok "Código generado desde templates/service-${stack}"

# ------------------------------------------------------------------ 2. repo en GitHub
(
  cd "$dest"
  git init -q -b master
  git add -A
  # Windows no guarda el bit de ejecución: se marca explícitamente en git
  git ls-files -z -- '*.sh' 'mvnw' '**/mvnw' | xargs -0 -r git update-index --chmod=+x
  # [skip ci]: el primer despliegue ocurre cuando el alta en GitOps esté aprobada.
  git commit -q -m "chore: alta del microservicio ${name} desde la plantilla ${type} [skip ci]"
)
gh repo create "${OWNER}/${name}" --public --description "$description" >/dev/null
git -C "$dest" push -q "$(git_url "${OWNER}/${name}")" master
# Rama principal de la organización: master (explícito, sin depender del primer push)
gh repo edit "${OWNER}/${name}" --default-branch master >/dev/null
ok "Repo https://github.com/${OWNER}/${name} (rama principal: master)"
configure_repo "${OWNER}/${name}" service

# ------------------------------------------------------------------ 3. Vault (secretos por ambiente)
info "Secretos en Vault: secret/apps/${name}/{dev,qa,prod}"
if [[ "$ci_mode" == true ]]; then
  bash .github/scripts/vault-seed-service.sh "$name" "$dest/deploy/vault/secrets.yaml" | tee -a "$summary"
else
  docker compose -f platform/docker-compose.yml run --rm -T toolbox bash /scripts/service-register.sh "$name" "$stack"
fi

# ------------------------------------------------------------------ 4. alta en GitOps (PR)
info "Abriendo PR de alta en ${GITOPS_REPO}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "$(git_url "${OWNER}/${GITOPS_REPO}")" "$tmp/gitops"
for env in dev qa prod; do
  mkdir -p "$tmp/gitops/apps/${name}/${env}"
  cat >"$tmp/gitops/apps/${name}/${env}/values.yaml" <<EOF
# ${name} · ${env}: snapshot GENERADO por el pipeline de CD de
# https://github.com/${OWNER}/${name} a partir de su carpeta deploy/.
# Mientras no haya una versión promovida (image.digest vacío) no se despliega nada.
image:
  digest: ""
EOF
done
pr_url="$(
  cd "$tmp/gitops"
  git checkout -q -b "chore/alta-${name}"
  git add -A
  git commit -q -m "feat(apps): alta del microservicio ${name}"
  git push -q -u origin "chore/alta-${name}"
  gh pr create --repo "${OWNER}/${GITOPS_REPO}" --head "chore/alta-${name}" \
    --title "feat(apps): alta del microservicio ${name}" --body "$(cat <<EOF
Alta de **${name}** (${type}) en los clústeres dev, qa y prod.

- Repo: https://github.com/${OWNER}/${name}
- Ruta pública: \`${api_path}\` sobre \`qt.<dominio del ambiente>\`
- Configuración por ambiente: \`deploy/\` del repo del servicio (la compone el pipeline al promover)
- Secretos: Vault \`secret/apps/${name}/<ambiente>\`

Generado por \`qt-infra/scripts/new-service.sh\`.
EOF
)"
)"
ok "PR de alta: ${pr_url}"

{
  echo "repo_url=https://github.com/${OWNER}/${name}"
  echo "gitops_pr=${pr_url}"
} >>"$output"
{
  echo "## ✅ Microservicio ${name} creado"
  echo "| | |"
  echo "|---|---|"
  echo "| Repo | https://github.com/${OWNER}/${name} |"
  echo "| Tipo | ${type} (${stack}) |"
  echo "| Ruta pública | \`${api_path}\` |"
  echo "| Alta en GitOps (requiere 1 admin) | ${pr_url} |"
} >>"$summary"

cat <<EOF

$(ok "Microservicio ${name} creado")
  Código:     ${dest}
  Repo:       https://github.com/${OWNER}/${name}
  Alta GitOps: ${pr_url}
  Ambientes:  dev (cada merge) → qa (cada release) → prod (release + aprobación de admins)

Siguientes pasos:
  1. Un admin aprueba el PR de alta en ${GITOPS_REPO} (se mergea solo).
  2. Clona el repo, crea una historia en el tablero, asígnatela y trabaja en la rama que se crea.
     Al mergear el primer PR, el CD despliega en dev.
EOF
