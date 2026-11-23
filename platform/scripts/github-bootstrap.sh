#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configura la organización en GitHub (plan Free, repos públicos). Idempotente.
#
#   Organización: teams admins/developers · política de Actions (allowlist,
#                 GITHUB_TOKEN de solo lectura, forks con aprobación) · runners
#                 self-hosted para repos públicos · tablero (GitHub Project) ·
#                 variables (VAULT_*, GITOPS_REPO, PROJECT_NUMBER...)
#   Repos:        qt-infra (este) y qt-gitops (generado), configurados y protegidos
#
# Requisitos (host, Git Bash): gh (winget install GitHub.cli) autenticado con
#   gh auth login -s admin:org,project,workflow
# y la plataforma arriba (qt up) para generar qt-gitops con la CA de Vault.
#
# Uso (raíz de qt-infra):
#   ADMINS="ana,luis" DEVELOPERS="pedro,maria" bash platform/scripts/github-bootstrap.sh
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=platform/scripts/lib-github.sh
source platform/scripts/lib-github.sh

[[ -f platform/.env ]] || die "Falta platform/.env (ejecuta primero: platform/qt.ps1 up)"
set -a
# shellcheck disable=SC1091
source platform/.env
set +a

OWNER="${GITHUB_OWNER:?}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
GITOPS_REPO="${GITOPS_REPO:-qt-gitops}"
: "${GOVERNANCE_APP_ID:?Define GOVERNANCE_APP_ID (App ID numérico de la GitHub App) en platform/.env}"
[[ "$GOVERNANCE_APP_ID" =~ ^[0-9]+$ ]] || die "GOVERNANCE_APP_ID debe ser numérico"
ADMIN_APPROVALS_REQUIRED="${ADMIN_APPROVALS_REQUIRED:-1}"
[[ "$ADMIN_APPROVALS_REQUIRED" =~ ^[1-6]$ ]] || die "ADMIN_APPROVALS_REQUIRED debe ser 1..6"
export ADMIN_APPROVALS_REQUIRED
PROJECT_TITLE="${PROJECT_TITLE:-QT Delivery}"

command -v gh >/dev/null || die "Instala GitHub CLI: winget install GitHub.cli"
gh auth status >/dev/null 2>&1 || die "Autentícate: gh auth login -s admin:org,project,workflow"
[[ -s platform/.secrets/tls/ca.b64 ]] || die "No existe la CA de Vault: ejecuta primero platform/qt.ps1 up"
gh api "orgs/${OWNER}" >/dev/null 2>&1 ||
  die "${OWNER} no es una organización. Crea una gratis: https://github.com/account/organizations/new?plan=free"
ok "Organización ${OWNER}"

# ------------------------------------------------------------------ 1. teams
ensure_team() {
  gh api "orgs/${OWNER}/teams/$1" >/dev/null 2>&1 ||
    { gh api -X POST "orgs/${OWNER}/teams" -f name="$1" -f description="$2" -f privacy=closed >/dev/null && ok "Team $1 creado"; }
}
ensure_team admins "Aprueban PRs, releases y despliegues a prod"
ensure_team developers "Desarrollo de microservicios"
for pair in "admins:${ADMINS:-}" "developers:${DEVELOPERS:-}"; do
  team="${pair%%:*}"
  for user in ${pair#*:}; do
    user="${user//,/}"
    [[ -z "$user" ]] && continue
    gh api -X PUT "orgs/${OWNER}/teams/${team}/memberships/${user}" -f role=member >/dev/null && ok "  @${user} → ${team}"
  done
done

# ------------------------------------------------------------------ 2. política de Actions (org)
gh api -X PUT "orgs/${OWNER}/actions/permissions" -f enabled_repositories=all -f allowed_actions=selected >/dev/null
gh api -X PUT "orgs/${OWNER}/actions/permissions/selected-actions" --input - >/dev/null <<JSON
{
  "github_owned_allowed": true,
  "verified_allowed": false,
  "patterns_allowed": [
    "${OWNER}/*",
    "docker/*",
    "hashicorp/vault-action@*",
    "aquasecurity/trivy-action@*",
    "aquasecurity/setup-trivy@*",
    "googleapis/release-please-action@*",
    "sigstore/cosign-installer@*",
    "SonarSource/sonarqube-scan-action@*"
  ]
}
JSON
gh api -X PUT "orgs/${OWNER}/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
gh api -X PUT "orgs/${OWNER}/actions/permissions/fork-pr-contributor-approval" \
  -f approval_policy=all_external_contributors >/dev/null ||
  warn "Configura a mano: Org settings → Actions → Require approval for all external contributors"
group_id="$(gh api "orgs/${OWNER}/actions/runner-groups" --jq '.runner_groups[] | select(.default) | .id')"
gh api -X PATCH "orgs/${OWNER}/actions/runner-groups/${group_id}" -F allows_public_repositories=true >/dev/null ||
  warn "Configura a mano: Org settings → Actions → Runner groups → Default → Allow public repositories"
ok "Actions: allowlist, GITHUB_TOKEN de solo lectura, forks con aprobación, runners para repos públicos"

# ------------------------------------------------------------------ 3. tablero (GitHub Project de la org)
PROJECT_NUMBER="${PROJECT_NUMBER:-$(gh project list --owner "$OWNER" --format json --limit 100 \
  --jq ".projects[] | select(.title == \"${PROJECT_TITLE}\") | .number" | head -n1)}"
if [[ -z "$PROJECT_NUMBER" ]]; then
  PROJECT_NUMBER="$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json --jq '.number')"
  ok "Tablero '${PROJECT_TITLE}' creado (#${PROJECT_NUMBER})"
fi
status_options="$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 50 \
  --jq '.fields[] | select(.name == "Status") | [.options[].name] | join(",")')"
if [[ "$status_options" != "Backlog,Ready,In Progress,In Review,Done" ]]; then
  status_field="$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 50 --jq '.fields[] | select(.name == "Status") | .id')"
  gh api graphql -f field="$status_field" -f query='
    mutation($field: ID!) {
      updateProjectV2Field(input: {fieldId: $field, singleSelectOptions: [
        {name: "Backlog",     color: GRAY,   description: "Historias por refinar"},
        {name: "Ready",       color: BLUE,   description: "Cumple la Definition of Ready"},
        {name: "In Progress", color: YELLOW, description: "Rama creada, en desarrollo"},
        {name: "In Review",   color: ORANGE, description: "PR abierto: CI + aprobación de admin"},
        {name: "Done",        color: GREEN,  description: "Mergeado en master"}
      ]}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } }
    }' >/dev/null
  ok "Columnas: Backlog → Ready → In Progress → In Review → Done"
fi
existing_fields="$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 50 --jq '[.fields[].name] | join("|")')"
ensure_field() {
  local name="$1"
  shift
  [[ "|${existing_fields}|" == *"|${name}|"* ]] ||
    { gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" --name "$name" "$@" >/dev/null && ok "Campo '${name}'"; }
}
ensure_field "Prioridad" --data-type SINGLE_SELECT --single-select-options "P0 - Crítica,P1 - Alta,P2 - Media,P3 - Baja"
ensure_field "Story points" --data-type NUMBER
ensure_field "Componente" --data-type SINGLE_SELECT --single-select-options "Backend,Frontend,Infraestructura"

# ------------------------------------------------------------------ 4. variables de la org (no secretos)
set_org_var() { gh variable set "$1" --org "$OWNER" --visibility all --body "$2" >/dev/null; }
set_org_var VAULT_ADDR "https://vault:8200"
set_org_var VAULT_AUDIENCE "${VAULT_AUDIENCE:-qt-vault}"
set_org_var VAULT_CA_B64 "$(cat platform/.secrets/tls/ca.b64)"
set_org_var GITOPS_REPO "$GITOPS_REPO"
set_org_var INFRA_REPO "$INFRA_REPO"
set_org_var GOVERNANCE_APP_ID "$GOVERNANCE_APP_ID"
set_org_var PROJECT_NUMBER "$PROJECT_NUMBER"
set_org_var ADMIN_APPROVALS_REQUIRED "${ADMIN_APPROVALS_REQUIRED}"
gh variable get DTRACK_ENABLED --org "$OWNER" >/dev/null 2>&1 || set_org_var DTRACK_ENABLED "false"
ok "Variables de la organización (ningún secreto vive en GitHub: todo sale de Vault vía OIDC)"

# ------------------------------------------------------------------ 5. qt-infra
if ! gh repo view "${OWNER}/${INFRA_REPO}" >/dev/null 2>&1; then
  gh repo create "${OWNER}/${INFRA_REPO}" --public --description "Plataforma QT: CI/CD, GitOps y plantillas de microservicios" >/dev/null
  ok "Repo ${INFRA_REPO} creado"
fi
if grep -q "__GITHUB_OWNER__" .github/CODEOWNERS; then
  sed -i "s/__GITHUB_OWNER__/${OWNER}/g" .github/CODEOWNERS
fi
if ! gh api "repos/${OWNER}/${INFRA_REPO}/commits?per_page=1" >/dev/null 2>&1; then
  info "Push inicial de ${INFRA_REPO} (antes de proteger master)"
  [[ -d .git ]] || git init -b master >/dev/null
  git checkout -B master >/dev/null 2>&1
  git add -A
  # Windows no guarda el bit de ejecución: se marca explícitamente en git
  git ls-files -z -- '*.sh' 'mvnw' '**/mvnw' | xargs -0 -r git update-index --chmod=+x
  git commit -m "chore: plataforma QT inicial" >/dev/null || true
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/${OWNER}/${INFRA_REPO}.git"
  git push -u origin master
fi
configure_repo "${OWNER}/${INFRA_REPO}" infra

# ------------------------------------------------------------------ 6. qt-gitops
if ! gh repo view "${OWNER}/${GITOPS_REPO}" >/dev/null 2>&1; then
  info "Generando ${GITOPS_REPO} (clusters dev/qa/prod con la CA y URL de Vault)"
  docker compose -f platform/docker-compose.yml run --rm -T toolbox bash /scripts/gitops-render.sh
  gh repo create "${OWNER}/${GITOPS_REPO}" --public --description "GitOps: estado deseado de los clústeres dev, qa y prod" >/dev/null
  (
    cd "platform/.generated/${GITOPS_REPO}"
    git init -b master >/dev/null
    git add -A
    git commit -m "chore: estado inicial de los clústeres dev, qa y prod" >/dev/null
    git remote add origin "https://github.com/${OWNER}/${GITOPS_REPO}.git"
    git push -u origin master
  )
  ok "Repo ${GITOPS_REPO} creado"
fi
configure_repo "${OWNER}/${GITOPS_REPO}" gitops

cat <<EOF

$(ok "Organización configurada")
  Tablero:  https://github.com/orgs/${OWNER}/projects/${PROJECT_NUMBER}
  Infra:    https://github.com/${OWNER}/${INFRA_REPO}
  GitOps:   https://github.com/${OWNER}/${GITOPS_REPO}

Siguientes pasos:
  1. Clústeres:     .\\qt.ps1 k8s-provision dev (servidores) o .\\qt.ps1 k8s-local dev (esta PC);
                    luego .\\qt.ps1 k8s-bootstrap dev   (igual para qa y prod)
  2. Microservicio: issue "Nuevo microservicio" en qt-infra + etiqueta aprobado
                    (o local: bash scripts/new-service.sh qt-backend backend)
  3. Manual (la API no lo expone): Tablero → Workflows → activa "Item closed" y "Pull request merged" (→ Done)
EOF
