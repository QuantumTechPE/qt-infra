#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Funciones de configuración de GitHub compartidas por github-bootstrap.sh y
# scripts/new-service.sh. Corren en el HOST (Git Bash) con `gh` autenticado.
# Requieren: OWNER, GOVERNANCE_APP_ID y estar en la raíz de qt-infra.
# -----------------------------------------------------------------------------

# gh con reintentos ante errores transitorios de GitHub (5xx, "unexpected EOF"...):
# un alta de microservicio o un bootstrap no deben cortarse a mitad por eso.
# shellcheck source=../../.github/scripts/lib-gh.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts/lib-gh.sh"

info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

admins_team_id() {
  if [[ -z "${ADMINS_TEAM_ID:-}" ]]; then
    ADMINS_TEAM_ID="$(gh api "orgs/${OWNER}/teams/admins" --jq '.id')"
  fi
  echo "$ADMINS_TEAM_ID"
}

# apply_ruleset <owner/repo> <archivo.json>   (crea o actualiza por nombre)
# Un ruleset con el nombre anterior "main-*" se actualiza en su lugar (queda
# renombrado a "master-*") en vez de duplicarse.
apply_ruleset() {
  local repo="$1" file="$2" name rendered id
  name="$(sed -n 's/^  "name": *"\([^"]*\)".*/\1/p' "$file" | head -n1)"
  rendered="$(sed -e "s/__GOVERNANCE_APP_ID__/${GOVERNANCE_APP_ID}/g" \
    -e "s/__ADMINS_TEAM_ID__/$(admins_team_id)/g" \
    -e "s/__REQUIRED_APPROVALS__/${ADMIN_APPROVALS_REQUIRED:-1}/g" "$file")"
  id="$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\" or .name == \"${name/#master-/main-}\") | .id" | head -n1)"
  if [[ -n "$id" ]]; then
    printf '%s' "$rendered" | gh api -X PUT "repos/${repo}/rulesets/${id}" --input - >/dev/null
  else
    printf '%s' "$rendered" | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null
  fi
}

# disable_github_security <owner/repo>: apaga secret scanning, push protection,
# alertas y actualizaciones de seguridad de Dependabot, code scanning (default
# setup) y el reporte privado de vulnerabilidades. Idempotente.
disable_github_security() {
  local repo="$1"
  gh api -X PATCH "repos/${repo}" --input - >/dev/null 2>&1 <<'JSON' || true
{ "security_and_analysis": {
    "secret_scanning": { "status": "disabled" },
    "secret_scanning_push_protection": { "status": "disabled" },
    "dependabot_security_updates": { "status": "disabled" } } }
JSON
  gh api -X DELETE "repos/${repo}/automated-security-fixes" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/${repo}/vulnerability-alerts" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/${repo}/private-vulnerability-reporting" >/dev/null 2>&1 || true
  gh api -X PATCH "repos/${repo}/code-scanning/default-setup" -f state=not-configured >/dev/null 2>&1 || true
}

# configure_repo <owner/repo> <service|infra|gitops|config>
configure_repo() {
  local repo="$1" kind="$2" l name color desc
  info "Configurando ${repo} (${kind})"

  gh api -X PUT "orgs/${OWNER}/teams/admins/repos/${repo}" -f permission=admin >/dev/null ||
    warn "  no se pudo asignar el team admins (revisa el permiso Members de la GitHub App)"
  gh api -X PUT "orgs/${OWNER}/teams/developers/repos/${repo}" -f permission=push >/dev/null ||
    warn "  no se pudo asignar el team developers"

  gh api -X PATCH "repos/${repo}" --input - >/dev/null <<'JSON'
{
  "has_issues": true,
  "has_projects": true,
  "has_wiki": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "allow_auto_merge": true,
  "allow_update_branch": true,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY"
}
JSON
  # "Security & quality" de GitHub DESACTIVADO por decisión de la organización:
  # las validaciones las hacen las herramientas propias de la plataforma en CICD
  # DEV (Gitleaks, Semgrep, Trivy, SonarQube), con sus propios quality gates.
  disable_github_security "$repo"

  local labels=(
    "type:story|0e8a16|Historia de usuario"
    "type:bug|d73a4a|Defecto"
    "type:task|1d76db|Tarea técnica"
    "dependencies|0366d6|Actualización de dependencias"
    "security|b60205|Seguridad"
  )
  for l in "${labels[@]}"; do
    IFS='|' read -r name color desc <<<"$l"
    gh label create "$name" --color "$color" --description "$desc" --repo "$repo" --force >/dev/null
  done

  if [[ "$kind" == "infra" ]]; then
    gh label create "nuevo-microservicio" --color "5319e7" --description "Solicitud de creación de un microservicio" --repo "$repo" --force >/dev/null
    gh label create "aprobado" --color "0e8a16" --description "Solicitud aprobada: dispara el workflow" --repo "$repo" --force >/dev/null
    gh api -X PUT "repos/${repo}/environments/provisioning" --input - >/dev/null <<JSON
{
  "reviewers": [ { "type": "Team", "id": $(admins_team_id) } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
    ok "  environment provisioning (crear microservicios requiere aprobación del team admins)"
  fi

  if [[ "$kind" == "service" ]]; then
    gh label create "pase" --color "b60205" --description "Pase a producción (lo abre el congelamiento)" --repo "$repo" --force >/dev/null

    # dev: SOLO ramas de historia (qt/*). Sin historia no hay despliegue.
    gh api -X PUT "repos/${repo}/environments/dev" --input - >/dev/null <<'JSON'
{ "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
    if ! gh api "repos/${repo}/environments/dev/deployment-branch-policies" \
      --jq '.branch_policies[].name' | grep -qx 'qt/\*'; then
      gh api -X POST "repos/${repo}/environments/dev/deployment-branch-policies" \
        -f name='qt/*' -f type=branch >/dev/null
    fi

    # cert y prod: solo master. La aprobación de producción se da al AGENDAR el
    # pase (pase-produccion); la ejecución a la hora agendada es automática.
    for env in cert prod; do
      gh api -X PUT "repos/${repo}/environments/${env}" --input - >/dev/null <<'JSON'
{ "reviewers": [], "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
JSON
    done
    gh api -X PUT "repos/${repo}/environments/pase-produccion" --input - >/dev/null <<JSON
{
  "prevent_self_review": false,
  "reviewers": [ { "type": "Team", "id": $(admins_team_id) } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
    ok "  environments: dev (ramas qt/*), cert y prod (master) y pase-produccion (aprobación del team admins)"
  fi

  if [[ "$kind" == "config" ]]; then
    # Promociones pre-develop → develop → master con merge commit (las ramas
    # comparten historia); los cambios entran a pre-develop con squash.
    gh api -X PATCH "repos/${repo}" -F allow_merge_commit=true       -f merge_commit_title=PR_TITLE -f merge_commit_message=PR_BODY >/dev/null
    # Cada ambiente aplica SOLO desde su rama (lo exige también Vault)
    local env branch
    for env in dev cert prod; do
      case "$env" in dev) branch=pre-develop ;; cert) branch=develop ;; prod) branch=master ;; esac
      gh api -X PUT "repos/${repo}/environments/${env}" --input - >/dev/null <<'JSON'
{ "reviewers": [], "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true } }
JSON
      if ! gh api "repos/${repo}/environments/${env}/deployment-branch-policies"         --jq '.branch_policies[].name' | grep -qx "$branch"; then
        gh api -X POST "repos/${repo}/environments/${env}/deployment-branch-policies"           -f name="$branch" -f type=branch >/dev/null
      fi
    done
    ok "  environments: dev (pre-develop), cert (develop) y prod (master)"
  elif [[ -n "${PROJECT_NUMBER:-}" ]]; then
    gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "$repo" >/dev/null 2>&1 || true
  fi

  case "$kind" in
    config)
      apply_ruleset "$repo" .github/rulesets/config-ramas-protegidas.json
      ok "  ruleset config-ramas-protegidas (pre-develop, develop y master: PR + CI + ${ADMIN_APPROVALS_REQUIRED:-1} aprobación(es) de admin)"
      if apply_ruleset "$repo" .github/rulesets/config-revisores-admins.json 2>/dev/null; then
        ok "  ruleset config-revisores-admins (GitHub exige la aprobación del team admins)"
      else
        warn "  'required reviewers' por team no disponible: lo cubre el check governance/admin-approvals"
      fi
      ;;
    gitops)
      apply_ruleset "$repo" .github/rulesets/master-protegida-gitops.json
      ok "  ruleset master-protegida-gitops (PR + ${ADMIN_APPROVALS_REQUIRED:-1} aprobación(es) de admin; la GitHub App escribe las promociones)"
      ;;
    *)
      apply_ruleset "$repo" .github/rulesets/master-protegida.json
      apply_ruleset "$repo" .github/rulesets/tags-release.json
      ok "  rulesets master-protegida + tags-release-inmutables"
      if apply_ruleset "$repo" .github/rulesets/master-revisores-admins.json 2>/dev/null; then
        ok "  ruleset master-revisores-admins (GitHub exige ${ADMIN_APPROVALS_REQUIRED:-1} aprobación(es) del team admins)"
      else
        warn "  'required reviewers' por team no disponible: lo cubre el check governance/admin-approvals"
      fi
      if [[ "$kind" == "service" ]]; then
        apply_ruleset "$repo" .github/rulesets/master-desplegado-dev.json
        ok "  ruleset master-desplegado-dev (solo se mergea si el último commit de la rama se desplegó en DEV y quedó Healthy)"
      fi
      ;;
  esac
}
