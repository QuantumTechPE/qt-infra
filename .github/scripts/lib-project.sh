#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Funciones compartidas: historias (código QT-n ↔ issue ↔ rama qt/<n>) y
# tablero de la organización (GitHub Projects v2).
#
# Lo usan story-flow.sh, story-deploy.sh, release.sh, cd-plan.sh y pr-lint.sh.
# Requiere: gh y jq. GH_TOKEN con lectura de issues (y escritura de proyectos
# para las funciones del tablero).
# -----------------------------------------------------------------------------

# Carriles del tablero (ciclo de vida de una historia hasta producción):
#
#   Backlog → Ready → In Progress → Despliegue DEV → Pruebas DEV (→ Rechazo DEV)
#   → Congelamiento (doing) → Congelamiento (done) → Pruebas QA (→ Rechazo QA)
#   → Gestión de pase → Ejecución de pase → Ratificación producción
#   (→ Rechazo producción) → Done (→ Reversión)
# shellcheck disable=SC2034 # variables de la librería: las usan los scripts que la cargan
LANES=(
  "Backlog" "Ready" "In Progress"
  "Despliegue DEV" "Pruebas DEV" "Rechazo DEV"
  "Congelamiento (doing)" "Congelamiento (done)" "Pruebas QA" "Rechazo QA"
  "Gestión de pase" "Ejecución de pase" "Ratificación producción" "Rechazo producción"
  "Done" "Reversión"
)
# shellcheck disable=SC2034
# Carriles desde los que un push a qt/<n> puede (re)desplegar en DEV: antes del
# congelamiento o después de un rechazo/reversión. Una historia en el flujo de
# QA/pase no se mueve por un push.
DEV_LANES=("" "Backlog" "Ready" "In Progress" "Despliegue DEV" "Pruebas DEV" "Rechazo DEV"
  "Rechazo QA" "Rechazo producción" "Reversión")

STORY_PREFIX="QT"
STORY_BRANCH_RE='^qt/([0-9]+)$'
# shellcheck disable=SC2034
PASE_LABEL="pase"

# ---------------------------------------------------------------- Historias
# code_from_branch <rama> → n (vacío si no es qt/<n>)
code_from_branch() {
  [[ "$1" =~ $STORY_BRANCH_RE ]] && echo "${BASH_REMATCH[1]}" || true
}

# code_from_title "[QT-7] Título" → 7
code_from_title() {
  [[ "$1" =~ ^\[${STORY_PREFIX}-([0-9]+)\] ]] && echo "${BASH_REMATCH[1]}" || true
}

# story_by_code <owner/repo> <n> [open|all] → "<node_id> <número> <título>"
# La historia es el issue del repo cuyo título empieza con [QT-<n>].
story_by_code() {
  local repo="$1" code="$2" state="${3:-open}"
  gh api --paginate "repos/${repo}/issues?state=${state}&per_page=100" \
    --jq ".[] | select(.pull_request == null) | select(.title | startswith(\"[${STORY_PREFIX}-${code}]\")) | \"\(.node_id) \(.number) \(.title)\"" |
    head -n1
}

# pr_story_code <owner/repo> <n° PR> → código de la historia (rama qt/<n>) o vacío
pr_story_code() {
  local head
  head="$(gh api "repos/$1/pulls/$2" --jq '.head.ref' 2>/dev/null || true)"
  code_from_branch "$head"
}

# stories_in_range <owner/repo> <rango git> → códigos (únicos) de las historias
# cuyos PRs se mergearon en ese rango (commits squash "título (#PR)").
stories_in_range() {
  local repo="$1" range="$2" pr code
  git log --format='%s' $range | grep -oE '\(#[0-9]+\)$' | tr -dc '0-9\n' |
    while read -r pr; do
      [[ -z "$pr" ]] && continue
      code="$(pr_story_code "$repo" "$pr")"
      [[ -n "$code" ]] && echo "$code"
    done | sort -un
}

# ---------------------------------------------------------------- Proyecto
PROJECT_JSON=""
# Carga el proyecto una sola vez en el shell principal (las funciones que lo
# consultan corren en subshells y no podrían cachearlo).
load_project() {
  : "${PROJECT_OWNER:?}" "${PROJECT_NUMBER:?}"
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
field_id() { project | jq -r --arg f "$1" '.fields.nodes[] | select(.name == $f) | .id'; }

# add_item <content-node-id> → item id (idempotente)
add_item() {
  gh api graphql -f project="$(project_id)" -f content="$1" -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
    }' --jq '.data.addProjectV2ItemById.item.id'
}

# set_select <content-node-id> <campo> <opción>
set_select() {
  local content="$1" field="$2" option="$3" item fid option_id
  fid="$(field_id "$field")"
  option_id="$(project | jq -r --arg f "$field" --arg o "$option" \
    '.fields.nodes[] | select(.name == $f) | .options[]? | select((.name | ascii_downcase) == ($o | ascii_downcase)) | .id')"
  if [[ -z "$fid" || -z "$option_id" ]]; then
    echo "::warning::Campo '${field}' u opción '${option}' inexistente en el proyecto; se omite."
    return 0
  fi
  item="$(add_item "$content")"
  gh api graphql -f project="$(project_id)" -f item="$item" -f field="$fid" -f option="$option_id" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
        value: {singleSelectOptionId: $option}}) { projectV2Item { id } }
    }' >/dev/null
}

# set_number <content-node-id> <campo> <número>
set_number() {
  local content="$1" field="$2" value="$3" item fid
  fid="$(field_id "$field")"
  [[ -z "$fid" ]] && return 0
  item="$(add_item "$content")"
  gh api graphql -f project="$(project_id)" -f item="$item" -f field="$fid" -F value="$value" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $value: Float!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
        value: {number: $value}}) { projectV2Item { id } }
    }' >/dev/null
}

# set_text <content-node-id> <campo> <texto>
set_text() {
  local content="$1" field="$2" value="$3" item fid
  fid="$(field_id "$field")"
  if [[ -z "$fid" ]]; then
    echo "::warning::Campo '${field}' inexistente en el proyecto; se omite."
    return 0
  fi
  item="$(add_item "$content")"
  gh api graphql -f project="$(project_id)" -f item="$item" -f field="$fid" -f value="$value" -f query='
    mutation($project: ID!, $item: ID!, $field: ID!, $value: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
        value: {text: $value}}) { projectV2Item { id } }
    }' >/dev/null
}

set_status() { set_select "$1" "Status" "$2"; }

# current_status <content-node-id> → carril actual en ESTE proyecto (o vacío)
current_status() {
  gh api graphql -f id="$1" -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on Issue {
          projectItems(first: 20) {
            nodes {
              project { id }
              fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            }
          }
        }
      }
    }' --jq ".data.node.projectItems.nodes[] | select(.project.id == \"$(project_id)\") | .fieldValueByName.name // \"\"" |
    head -n1
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------- Issues
# issue_node <owner/repo> <n°> → node id
issue_node() { gh api "repos/$1/issues/$2" --jq '.node_id'; }

# comment <owner/repo> <n°> <texto>
comment() { gh api -X POST "repos/$1/issues/$2/comments" -f body="$3" >/dev/null; }

# Datos de máquina del issue de pase (JSON en un comentario HTML del cuerpo)
# pase_data <owner/repo> <n°> → JSON
pase_data() {
  gh api "repos/$1/issues/$2" --jq '.body' |
    sed -n 's/^<!-- qt-pase \(.*\) -->$/\1/p' | head -n1
}

# recreate_branch <owner/repo> <n° issue> <código>: rama qt/<n> desde master
# (para corregir tras un rechazo; la anterior se borró al mergear)
recreate_branch() {
  local repo="$1" number="$2" code="$3" branch="qt/$3" sha repo_id node
  if gh api "repos/${repo}/git/ref/heads/${branch}" >/dev/null 2>&1; then
    echo "la rama ${branch} ya existe"
    return 0
  fi
  sha="$(gh api "repos/${repo}/git/ref/heads/$(gh api "repos/${repo}" --jq .default_branch)" --jq '.object.sha')"
  repo_id="$(gh api "repos/${repo}" --jq '.node_id')"
  node="$(issue_node "$repo" "$number")"
  gh api graphql -f issue="$node" -f oid="$sha" -f name="$branch" -f repo="$repo_id" -f query='
    mutation($issue: ID!, $oid: GitObjectID!, $name: String!, $repo: ID!) {
      createLinkedBranch(input: {issueId: $issue, oid: $oid, name: $name, repositoryId: $repo}) {
        linkedBranch { ref { name } }
      }
    }' >/dev/null
  echo "rama ${branch} creada desde ${sha:0:7}"
}

# permission <owner/repo> <usuario> → admin | maintain | write | triage | read | none
permission() { gh api "repos/$1/collaborators/$2/permission" --jq '.permission' 2>/dev/null || echo none; }
