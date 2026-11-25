#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Ramas al día (lo ejecuta qt-infra cada 5 minutos, para TODOS los repos de la
# organización, también los que se creen después).
#
# Cuando master avanza, los PRs ya aprobados quedan "atrasados" y el ruleset
# (checks estrictos) no los deja mergear. Este script actualiza esas ramas
# (merge de master en la rama, como el botón "Update branch"):
#   - CI vuelve a correr sobre el commit nuevo;
#   - en microservicios, el push a qt/<n> dispara CICD DEV, que vuelve a desplegar
#     en DEV y publica "deploy/dev";
#   - la aprobación del admin se mantiene (no es un cambio de código nuevo) y el
#     auto-merge termina el trabajo.
#
# Solo toca PRs abiertos, que no son borrador, con base en la rama principal,
# rama en el mismo repo (no forks) y gobierno aprobado (governance/admin-approvals).
#
# Entradas: GH_TOKEN (GitHub App de la organización), OWNER
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${OWNER:?}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "## Ramas al día ($(date -u +%FT%TZ))" >>"$summary"
updated=0

for repo in $(gh api --paginate "orgs/${OWNER}/repos?per_page=100" --jq '.[] | select(.archived | not) | .name'); do
  prs="$(gh api graphql -f owner="$OWNER" -f name="$repo" -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        pullRequests(states: OPEN, first: 50) {
          nodes {
            number isDraft mergeStateStatus baseRefName headRefOid isCrossRepository
            commits(last: 1) { nodes { commit { status { context(name: "governance/admin-approvals") { state } } } } }
          }
        }
      }
    }' --jq '.data.repository as $r | $r.pullRequests.nodes[]
      | select(.isDraft | not) | select(.isCrossRepository | not)
      | select(.baseRefName == $r.defaultBranchRef.name)
      | select(.mergeStateStatus == "BEHIND")
      | select(.commits.nodes[0].commit.status.context.state == "SUCCESS")
      | "\(.number) \(.headRefOid)"' 2>/dev/null || true)"
  [[ -z "$prs" ]] && continue
  while read -r number head; do
    if gh api -X PUT "repos/${OWNER}/${repo}/pulls/${number}/update-branch" -f expected_head_sha="$head" >/dev/null 2>&1; then
      echo "- 🔄 \`${repo}\` PR #${number}: rama actualizada con la rama principal" | tee -a "$summary"
      updated=$((updated + 1))
    else
      echo "- ⚠️ \`${repo}\` PR #${number}: no se pudo actualizar (¿conflictos? resuélvelos en la rama)" | tee -a "$summary"
    fi
  done <<<"$prs"
done

((updated > 0)) || echo "- Ningún PR aprobado atrasado." >>"$summary"
