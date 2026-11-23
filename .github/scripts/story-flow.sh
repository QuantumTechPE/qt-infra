#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Flujo historia de usuario ↔ GitHub Projects ↔ código.
#
#   issue abierto / reabierto     → tablero: Backlog (+ Prioridad, Story points, Componente)
#   issue asignado                → crea rama <tipo>/<n>-<slug> vinculada al issue → In Progress
#   PR abierto / listo            → historias vinculadas → In Review
#   PR vuelve a borrador          → historias vinculadas → In Progress
#   PR mergeado                   → historias vinculadas → Done
#   issue cerrado                 → Done
#
# Entradas: GH_TOKEN (GitHub App), REPO, PROJECT_OWNER, PROJECT_NUMBER,
#           GITHUB_EVENT_NAME, GITHUB_EVENT_PATH (los pone GitHub Actions)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${PROJECT_OWNER:?}" "${PROJECT_NUMBER:?}"
: "${GITHUB_EVENT_NAME:?}" "${GITHUB_EVENT_PATH:?}"

EVENT="$GITHUB_EVENT_PATH"
action="$(jq -r '.action' "$EVENT")"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
log() { echo "$*"; echo "- $*" >>"$summary"; }

# ---------------------------------------------------------------- Projects v2
PROJECT_JSON=""
# Carga el proyecto una sola vez en el shell principal (las funciones que lo
# consultan corren en subshells y no podrían cachearlo).
load_project() {
  PROJECT_JSON="$(gh api graphql -F number="$PROJECT_NUMBER" -f owner="$PROJECT_OWNER" -f query='
      query($owner: String!, $number: Int!) {
        repositoryOwner(login: $owner) {
          ... on ProjectV2Owner {
            projectV2(number: $number) {
              id
              fields(first: 50) {
                nodes {
                  ... on ProjectV2FieldCommon { id name dataType }
                  ... on ProjectV2SingleSelectField { options { id name } }
                }
              }
            }
          }
        }
      }' --jq '.data.repositoryOwner.projectV2')"
  if [[ -z "$PROJECT_JSON" || "$PROJECT_JSON" == "null" ]]; then
    echo "::error::No se encontró el proyecto #${PROJECT_NUMBER} de ${PROJECT_OWNER} (¿la GitHub App tiene permiso Projects: read & write?)"
    exit 1
  fi
}

project() { echo "$PROJECT_JSON"; }

project_id() { project | jq -r '.id'; }

# add_item <content-node-id> → item id (idempotente)
add_item() {
  gh api graphql -f project="$(project_id)" -f content="$1" -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
    }' --jq '.data.addProjectV2ItemById.item.id'
}

# set_select <content-node-id> <campo> <opción>
set_select() {
  local content="$1" field="$2" option="$3" item field_id option_id
  field_id="$(project | jq -r --arg f "$field" '.fields.nodes[] | select(.name == $f) | .id')"
  option_id="$(project | jq -r --arg f "$field" --arg o "$option" \
    '.fields.nodes[] | select(.name == $f) | .options[]? | select((.name | ascii_downcase) == ($o | ascii_downcase)) | .id')"
  if [[ -z "$field_id" || -z "$option_id" ]]; then
    echo "::warning::Campo '${field}' u opción '${option}' inexistente en el proyecto; se omite."
    return 0
  fi
  item="$(add_item "$content")"
  gh api graphql -f project="$(project_id)" -f item="$item" -f field="$field_id" -f option="$option_id" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
        value: {singleSelectOptionId: $option}}) { projectV2Item { id } }
    }' >/dev/null
}

# set_number <content-node-id> <campo> <número>
set_number() {
  local content="$1" field="$2" value="$3" item field_id
  field_id="$(project | jq -r --arg f "$field" '.fields.nodes[] | select(.name == $f) | .id')"
  [[ -z "$field_id" ]] && return 0
  item="$(add_item "$content")"
  gh api graphql -f project="$(project_id)" -f item="$item" -f field="$field_id" -F value="$value" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $value: Float!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
        value: {number: $value}}) { projectV2Item { id } }
    }' >/dev/null
}

set_status() { set_select "$1" "Status" "$2"; }

# Valor de una sección "### <Título>" de un issue form.
form_value() {
  local body="$1" heading="$2"
  awk -v h="### ${heading}" '
    $0 == h { found = 1; next }
    found && /^### / { exit }
    found && NF { print; exit }
  ' <<<"$body" | tr -d '\r'
}

# ---------------------------------------------------------------- Issues
issue_opened() {
  local node number body prio points comp
  node="$(jq -r '.issue.node_id' "$EVENT")"
  number="$(jq -r '.issue.number' "$EVENT")"
  body="$(jq -r '.issue.body // ""' "$EVENT")"

  set_status "$node" "Backlog"
  log "#${number} → **Backlog**"

  prio="$(form_value "$body" "Prioridad")"
  if [[ -n "$prio" && "$prio" != "_No response_" ]]; then
    set_select "$node" "Prioridad" "$prio"
    log "#${number} prioridad: ${prio}"
  fi

  points="$(form_value "$body" "Story points")"
  if [[ "$points" =~ ^[0-9]+$ ]]; then
    set_number "$node" "Story points" "$points"
    log "#${number} story points: ${points}"
  fi

  comp="$(form_value "$body" "Componente")"
  comp="${comp%%,*}" # el campo del tablero es de selección simple: se toma el primero
  if [[ -n "$comp" && "$comp" != "_No response_" ]]; then
    set_select "$node" "Componente" "$comp"
    log "#${number} componente: ${comp}"
  fi
}

slugify() {
  local s
  s="$(printf '%s' "$1" | sed -E 's/^\[[A-Za-z]+\][[:space:]]*//')"            # quita prefijo [HU]/[BUG]
  s="$(printf '%s' "$s" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || printf '%s' "$s")"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:0:40}" | sed -E 's/-+$//'
}

issue_assigned() {
  local node number title labels prefix owner name existing branch main_sha repo_id
  node="$(jq -r '.issue.node_id' "$EVENT")"
  number="$(jq -r '.issue.number' "$EVENT")"
  title="$(jq -r '.issue.title' "$EVENT")"
  labels="$(jq -r '[.issue.labels[].name] | join(",")' "$EVENT")"

  case ",${labels}," in
    *,type:bug,*) prefix="fix" ;;
    *,type:task,*) prefix="chore" ;;
    *,type:story,*) prefix="feature" ;;
    *) log "#${number} sin label type:story/bug/task: no se crea rama."; return 0 ;;
  esac

  owner="${REPO%/*}"; name="${REPO#*/}"
  existing="$(gh api graphql -f owner="$owner" -f name="$name" -F number="$number" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) { linkedBranches(first: 1) { nodes { ref { name } } } }
      }
    }' --jq '.data.repository.issue.linkedBranches.nodes[0].ref.name // ""')"

  if [[ -n "$existing" ]]; then
    log "#${number} ya tiene la rama \`${existing}\`."
  else
    branch="${prefix}/${number}-$(slugify "$title")"
    main_sha="$(gh api "repos/${REPO}/git/ref/heads/$(gh api "repos/${REPO}" --jq .default_branch)" --jq '.object.sha')"
    repo_id="$(gh api "repos/${REPO}" --jq '.node_id')"
    gh api graphql -f issue="$node" -f oid="$main_sha" -f name="$branch" -f repo="$repo_id" -f query='
      mutation($issue: ID!, $oid: GitObjectID!, $name: String!, $repo: ID!) {
        createLinkedBranch(input: {issueId: $issue, oid: $oid, name: $name, repositoryId: $repo}) {
          linkedBranch { ref { name } }
        }
      }' >/dev/null
    gh api -X POST "repos/${REPO}/issues/${number}/comments" -f body="$(cat <<EOF
🚀 **Rama creada:** \`${branch}\` (desde \`${main_sha:0:7}\`)

\`\`\`bash
git fetch origin
git switch ${branch}
\`\`\`

Al abrir el PR usa un título [Conventional Commits](https://www.conventionalcommits.org/es/) e incluye \`Closes #${number}\`.
El merge es automático cuando **2 admins** aprueban y el pipeline queda en verde.
EOF
)" >/dev/null
    log "#${number} → rama \`${branch}\` creada y vinculada"
  fi

  set_status "$node" "In Progress"
  log "#${number} → **In Progress**"
}

issue_closed() {
  local node number reason
  node="$(jq -r '.issue.node_id' "$EVENT")"
  number="$(jq -r '.issue.number' "$EVENT")"
  reason="$(jq -r '.issue.state_reason // "completed"' "$EVENT")"
  if [[ "$reason" == "completed" ]]; then
    set_status "$node" "Done"
    log "#${number} → **Done**"
  else
    log "#${number} cerrado como ${reason}: no se mueve en el tablero."
  fi
}

# ---------------------------------------------------------------- Pull requests
linked_issues() {
  local owner="${REPO%/*}" name="${REPO#*/}" number
  number="$(jq -r '.pull_request.number' "$EVENT")"
  gh api graphql -f owner="$owner" -f name="$name" -F number="$number" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          closingIssuesReferences(first: 10) { nodes { id number } }
        }
      }
    }' --jq '.data.repository.pullRequest.closingIssuesReferences.nodes[] | "\(.id) \(.number)"'
}

move_linked() {
  local status="$1" id number found=false
  while read -r id number; do
    [[ -z "$id" ]] && continue
    found=true
    set_status "$id" "$status"
    log "#${number} → **${status}**"
  done < <(linked_issues)
  [[ "$found" == true ]] || log "El PR no referencia historias con \`Closes #N\`."
}

pr_event() {
  local draft merged
  draft="$(jq -r '.pull_request.draft' "$EVENT")"
  merged="$(jq -r '.pull_request.merged' "$EVENT")"
  case "$action" in
    opened | reopened | ready_for_review)
      if [[ "$draft" == "true" ]]; then move_linked "In Progress"; else move_linked "In Review"; fi ;;
    converted_to_draft) move_linked "In Progress" ;;
    closed)
      if [[ "$merged" == "true" ]]; then move_linked "Done"; else move_linked "In Progress"; fi ;;
  esac
}

# ---------------------------------------------------------------- Router
echo "## Tablero (evento: ${GITHUB_EVENT_NAME}/${action})" >>"$summary"
load_project
case "$GITHUB_EVENT_NAME" in
  issues)
    case "$action" in
      opened | reopened) issue_opened ;;
      assigned) issue_assigned ;;
      closed) issue_closed ;;
    esac ;;
  pull_request_target) pr_event ;;
  *) echo "Evento no soportado: ${GITHUB_EVENT_NAME}" ;;
esac
