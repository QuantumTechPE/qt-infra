#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Gobierno de merges: "un admin aprueba → merge automático".
#
# Para un PR dado:
#   1. Toma la última revisión de cada usuario (sin contar al autor).
#   2. Cuenta los APPROVED de usuarios con rol `admin` en el repositorio.
#   3. Publica el commit status `governance/admin-approvals` (requerido por el
#      ruleset de main y firmado por la GitHub App: nadie más puede falsearlo).
#   4. Si llega al mínimo, habilita auto-merge (squash). GitHub mergea solo
#      cuando además todos los checks requeridos estén en verde.
#
# Entradas: GH_TOKEN (token de la GitHub App), REPO (owner/repo), PR_NUMBER
# Opcional: ADMIN_APPROVALS_REQUIRED (default 1)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN (GitHub App) requerido}"
: "${REPO:?REPO requerido}"
: "${PR_NUMBER:?PR_NUMBER requerido}"
REQUIRED="${ADMIN_APPROVALS_REQUIRED:-1}"
CONTEXT="governance/admin-approvals"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

pr="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}")"
state="$(jq -r '.state' <<<"$pr")"
draft="$(jq -r '.draft' <<<"$pr")"
head_sha="$(jq -r '.head.sha' <<<"$pr")"
author="$(jq -r '.user.login' <<<"$pr")"
node_id="$(jq -r '.node_id' <<<"$pr")"
html_url="$(jq -r '.html_url' <<<"$pr")"

if [[ "$state" != "open" ]]; then
  echo "PR #${PR_NUMBER} no está abierto (${state}); nada que hacer."
  exit 0
fi

set_status() {
  local st="$1" desc="$2"
  gh api -X POST "repos/${REPO}/statuses/${head_sha}" \
    -f state="$st" -f context="$CONTEXT" -f description="${desc:0:140}" -f target_url="$html_url" >/dev/null
  echo "Status ${CONTEXT}=${st}: ${desc}"
}

if [[ "$draft" == "true" ]]; then
  set_status pending "PR en borrador: márcalo como listo para revisión"
  exit 0
fi

# Última revisión "decisiva" de cada usuario (COMMENTED no cambia el veredicto).
approvers="$(gh api --paginate "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" \
  --jq '.[] | {user: .user.login, state: .state, at: .submitted_at}' |
  jq -rs --arg author "$author" '
    map(select(.state != "COMMENTED" and .state != "PENDING"))
    | group_by(.user)
    | map(max_by(.at))
    | map(select(.state == "APPROVED" and .user != $author))
    | .[].user')"

admins=()
while IFS= read -r user; do
  [[ -z "$user" ]] && continue
  role="$(gh api "repos/${REPO}/collaborators/${user}/permission" --jq '.role_name // .permission' 2>/dev/null || echo none)"
  if [[ "$role" == "admin" ]]; then
    admins+=("$user")
  fi
done <<<"$approvers"

count=${#admins[@]}
who=""
((count > 0)) && who=" ($(printf '@%s ' "${admins[@]}" | sed 's/ $//'))"

{
  echo "## Gobierno de merge — PR #${PR_NUMBER}"
  echo "- Aprobaciones de admins: **${count}/${REQUIRED}**${who}"
} >>"$summary"

if ((count < REQUIRED)); then
  set_status pending "${count}/${REQUIRED} aprobaciones de admins${who}"
  exit 0
fi

set_status success "${count}/${REQUIRED} aprobaciones de admins${who}"

# Habilita auto-merge. Si el PR ya está 100% listo GitHub rechaza el auto-merge
# ("clean status"): en ese caso se mergea directamente.
if gh api graphql \
  -f query='mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { pullRequest { number } } }' \
  -f id="$node_id" >/dev/null 2>&1; then
  echo "- 🤖 Auto-merge habilitado: se mergea cuando el CI quede en verde." >>"$summary"
else
  mergeable_state="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.mergeable_state')"
  if [[ "$mergeable_state" == "clean" ]]; then
    gh api -X PUT "repos/${REPO}/pulls/${PR_NUMBER}/merge" -f merge_method=squash -f sha="$head_sha" >/dev/null
    echo "- ✅ PR mergeado (squash)." >>"$summary"
  else
    echo "::warning::No se pudo habilitar auto-merge (mergeable_state=${mergeable_state}). Revisa 'Allow auto-merge' en el repo."
    echo "- ⚠️ No se habilitó auto-merge (estado: ${mergeable_state})." >>"$summary"
  fi
fi
