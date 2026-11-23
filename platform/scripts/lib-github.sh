#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Funciones de configuración de GitHub compartidas por github-bootstrap.sh y
# scripts/new-service.sh. Corren en el HOST (Git Bash) con `gh` autenticado.
# Requieren: OWNER, GOVERNANCE_APP_ID y estar en la raíz de qt-infra.
# -----------------------------------------------------------------------------

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
apply_ruleset() {
  local repo="$1" file="$2" name rendered id
  name="$(sed -n 's/^  "name": *"\([^"]*\)".*/\1/p' "$file" | head -n1)"
  rendered="$(sed -e "s/__GOVERNANCE_APP_ID__/${GOVERNANCE_APP_ID}/g" \
    -e "s/__ADMINS_TEAM_ID__/$(admins_team_id)/g" \
    -e "s/__REQUIRED_APPROVALS__/${ADMIN_APPROVALS_REQUIRED:-2}/g" "$file")"
  id="$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\") | .id")"
  if [[ -n "$id" ]]; then
    printf '%s' "$rendered" | gh api -X PUT "repos/${repo}/rulesets/${id}" --input - >/dev/null
  else
    printf '%s' "$rendered" | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null
  fi
}

# configure_repo <owner/repo> <service|infra|gitops>
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
  gh api -X PATCH "repos/${repo}" --input - >/dev/null 2>&1 <<'JSON' || true
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
JSON
  gh api -X PUT "repos/${repo}/vulnerability-alerts" >/dev/null
  gh api -X PUT "repos/${repo}/automated-security-fixes" >/dev/null || true
  gh api -X PUT "repos/${repo}/private-vulnerability-reporting" >/dev/null || true

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
    for env in dev qa; do
      gh api -X PUT "repos/${repo}/environments/${env}" --input - >/dev/null <<'JSON'
{ "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
JSON
    done
    gh api -X PUT "repos/${repo}/environments/prod" --input - >/dev/null <<JSON
{
  "prevent_self_review": true,
  "reviewers": [ { "type": "Team", "id": $(admins_team_id) } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
JSON
    ok "  environments: dev, qa (automáticos) y prod (aprobación del team admins)"
  fi

  if [[ -n "${PROJECT_NUMBER:-}" ]]; then
    gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "$repo" >/dev/null 2>&1 || true
  fi

  case "$kind" in
    gitops)
      apply_ruleset "$repo" .github/rulesets/main-protegida-gitops.json
      ok "  ruleset main-protegida-gitops (PR + 2 admins; la GitHub App escribe las promociones)"
      ;;
    *)
      apply_ruleset "$repo" .github/rulesets/main-protegida.json
      apply_ruleset "$repo" .github/rulesets/tags-release.json
      ok "  rulesets main-protegida + tags-release-inmutables"
      if apply_ruleset "$repo" .github/rulesets/main-revisores-admins.json 2>/dev/null; then
        ok "  ruleset main-revisores-admins (GitHub exige 2 aprobaciones del team admins)"
      else
        warn "  'required reviewers' por team no disponible: lo cubre el check governance/admin-approvals"
      fi
      ;;
  esac
}
