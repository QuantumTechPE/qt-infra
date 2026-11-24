#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Flujo historia de usuario ↔ tablero ↔ código.
#
#   issue abierto (historia, bug o tarea) → código correlativo QT-<n> de la
#       organización: título "[QT-<n>] …", campo "Código" y carril Backlog
#   issue asignado      → rama qt/<n> vinculada a la historia → In Progress
#   "/rechazar <motivo>" en la historia (Pruebas DEV) → Rechazo DEV
#   PR desde qt/<n>     → la descripción enlaza la historia ("Historia: #N")
#
# Los despliegues mueven el resto de carriles (story-board.sh, pase.sh).
#
# Entradas: GH_TOKEN (GitHub App), REPO, PROJECT_OWNER, PROJECT_NUMBER,
#           GITHUB_EVENT_NAME, GITHUB_EVENT_PATH (los pone GitHub Actions)
#           VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT (contador de códigos)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${GITHUB_EVENT_NAME:?}" "${GITHUB_EVENT_PATH:?}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"

EVENT="$GITHUB_EVENT_PATH"
action="$(jq -r '.action' "$EVENT")"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
log() { echo "$*"; echo "- $*" >>"$summary"; }

# ---------------------------------------------------------------- Código QT-<n>
# Contador único de la organización en Vault (KV v2) con check-and-set: dos
# historias creadas a la vez en repos distintos nunca reciben el mismo código.
next_code() {
  : "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
  local url="${VAULT_ADDR}/v1/secret/data/platform/story-seq" resp status body current version next
  local ca=()
  [[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")
  for _ in $(seq 1 10); do
    resp="$(curl -sS "${ca[@]}" -H "X-Vault-Token: ${VAULT_TOKEN}" -w $'\n%{http_code}' "$url")"
    status="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    case "$status" in
      404) current=0; version=0 ;;
      200)
        current="$(jq -r '.data.data.last // 0' <<<"$body")"
        version="$(jq -r '.data.metadata.version' <<<"$body")"
        ;;
      *) echo "::error::Vault respondió ${status} al leer el contador de historias" >&2; return 1 ;;
    esac
    next=$((current + 1))
    if curl -fsS "${ca[@]}" -H "X-Vault-Token: ${VAULT_TOKEN}" -X POST "$url" \
      -d "{\"options\":{\"cas\":${version}},\"data\":{\"last\":${next}}}" >/dev/null 2>&1; then
      echo "$next"
      return 0
    fi
    sleep $((RANDOM % 3 + 1)) # otro issue tomó el número: reintento
  done
  echo "::error::No se pudo reservar un código de historia" >&2
  return 1
}

# Valor de una sección "### <Título>" de un issue form.
form_value() {
  local body="$1" heading="$2"
  awk -v h="### ${heading}" '
    $0 == h { found = 1; next }
    found && /^### / { exit }
    found && NF { print; exit }
  ' <<<"$body" | tr -d '\r'
}

is_work_item() { [[ ",$1," =~ ,type:(story|bug|task), ]]; }

# ---------------------------------------------------------------- Issues
issue_opened() {
  local node number title body labels code clean prio points comp
  node="$(jq -r '.issue.node_id' "$EVENT")"
  number="$(jq -r '.issue.number' "$EVENT")"
  title="$(jq -r '.issue.title' "$EVENT")"
  body="$(jq -r '.issue.body // ""' "$EVENT")"
  labels="$(jq -r '[.issue.labels[].name] | join(",")' "$EVENT")"

  # Los issues de pase los gestiona el pipeline (pase.sh)
  [[ ",${labels}," == *",${PASE_LABEL},"* ]] && { log "#${number} es un pase: lo gestiona el pipeline."; return 0; }

  code="$(code_from_title "$title")"
  if [[ -z "$code" ]] && is_work_item "$labels"; then
    code="$(next_code)"
    clean="$(sed -E 's/^(\[[^]]*\][[:space:]]*)+//' <<<"$title")"
    gh api -X PATCH "repos/${REPO}/issues/${number}" -f title="[${STORY_PREFIX}-${code}] ${clean}" >/dev/null
    comment "$REPO" "$number" "$(cat <<EOF
🏷️ Código **${STORY_PREFIX}-${code}** · al asignarla se crea la rama \`qt/${code}\`.

| Para… | Haz esto | Carril |
|---|---|---|
| Desplegar en DEV | \`git push\` a \`qt/${code}\` | Despliegue DEV → Pruebas DEV |
| Rechazar en pruebas DEV | Comenta aquí \`/rechazar <motivo>\` | Rechazo DEV |
| Llevar a QA | PR \`qt/${code}\` → \`master\` aprobado por un admin | Congelamiento → Pruebas QA |
| Pasar a producción | En el **issue de pase** que abre el congelamiento: \`/rechazar\`, \`/agendar AAAA-MM-DD HH:MM\`, \`/ratificar\`, \`/revertir\` | Gestión de pase → … → Done |

Los carriles los mueve la plataforma; arrastrar la tarjeta no despliega nada.
EOF
)"
    log "#${number} → código **${STORY_PREFIX}-${code}**"
  fi

  load_project
  [[ -n "$code" ]] && set_text "$node" "Código" "${STORY_PREFIX}-${code}"
  if [[ "$action" == "opened" ]]; then
    set_status "$node" "Backlog"
    log "#${number} → **Backlog**"
  fi

  prio="$(form_value "$body" "Prioridad")"
  if [[ -n "$prio" && "$prio" != "_No response_" ]]; then
    set_select "$node" "Prioridad" "$prio"
  fi
  points="$(form_value "$body" "Story points")"
  [[ "$points" =~ ^[0-9]+$ ]] && set_number "$node" "Story points" "$points"
  comp="$(form_value "$body" "Componente")"
  comp="${comp%%,*}" # el campo del tablero es de selección simple: se toma el primero
  if [[ -n "$comp" && "$comp" != "_No response_" ]]; then
    set_select "$node" "Componente" "$comp"
  fi
}

issue_assigned() {
  local node number title code
  node="$(jq -r '.issue.node_id' "$EVENT")"
  number="$(jq -r '.issue.number' "$EVENT")"
  title="$(jq -r '.issue.title' "$EVENT")"
  code="$(code_from_title "$title")"
  if [[ -z "$code" ]]; then
    log "#${number} no tiene código ${STORY_PREFIX}-<n> (no es historia, bug ni tarea): no se crea rama."
    return 0
  fi

  log "#${number}: $(recreate_branch "$REPO" "$number" "$code")"
  comment "$REPO" "$number" "$(cat <<EOF
🚀 **Rama \`qt/${code}\`** lista para **${STORY_PREFIX}-${code}**.

\`\`\`bash
git fetch origin
git switch qt/${code}
\`\`\`

| Paso | Qué pasa |
|---|---|
| \`git push\` a \`qt/${code}\` | Se despliega en **DEV** (Despliegue DEV → Pruebas DEV) |
| Rechazo en pruebas DEV | Comenta \`/rechazar <motivo>\` aquí → Rechazo DEV |
| PR \`qt/${code}\` → \`master\` aprobado | **Congelamiento** en QA y se abre el issue de **pase** |

Sin historia no hay despliegue: solo las ramas \`qt/<n>\` de una historia abierta llegan a DEV.
EOF
)"
  load_project
  local current
  current="$(current_status "$node")"
  if in_list "$current" "${DEV_LANES[@]}"; then
    set_status "$node" "In Progress"
    log "#${number} → **In Progress**"
  fi
}

# "/rechazar <motivo>" en una historia que está en pruebas DEV
issue_comment() {
  local body number node title code current user perm reason
  body="$(jq -r '.comment.body' "$EVENT" | tr -d '\r')"
  [[ "$body" =~ ^/rechazar ]] || return 0
  [[ "$(jq -r '.issue.pull_request // empty' "$EVENT")" == "" ]] || return 0
  number="$(jq -r '.issue.number' "$EVENT")"
  title="$(jq -r '.issue.title' "$EVENT")"
  code="$(code_from_title "$title")"
  [[ -n "$code" ]] || return 0
  # Los rechazos de QA/producción se comentan en el issue de pase
  [[ ",$(jq -r '[.issue.labels[].name] | join(",")' "$EVENT")," == *",${PASE_LABEL},"* ]] && return 0

  user="$(jq -r '.comment.user.login' "$EVENT")"
  perm="$(permission "$REPO" "$user")"
  if ! in_list "$perm" admin maintain write triage; then
    comment "$REPO" "$number" "⛔ @${user} no tiene permisos para rechazar."
    return 0
  fi
  node="$(jq -r '.issue.node_id' "$EVENT")"
  load_project
  current="$(current_status "$node")"
  if ! in_list "$current" "Despliegue DEV" "Pruebas DEV"; then
    comment "$REPO" "$number" "ℹ️ \`/rechazar\` aquí aplica en **Pruebas DEV** (ahora: ${current:-sin carril}). Para QA o producción comenta en el issue de pase."
    return 0
  fi
  reason="$(sed -E 's#^/rechazar[[:space:]]*##' <<<"$body" | head -n1)"
  set_status "$node" "Rechazo DEV"
  comment "$REPO" "$number" "❌ **Rechazo DEV** por @${user}: ${reason:-sin motivo}. Corrige en \`qt/${code}\` y haz push para volver a desplegar."
  log "#${number} → **Rechazo DEV**"
}

# ---------------------------------------------------------------- Pull requests
# El PR desde qt/<n> queda enlazado a su historia (sin cerrarla: la cierra la
# ratificación en producción).
pr_event() {
  local head number body code story
  [[ "$action" == "opened" || "$action" == "reopened" ]] || return 0
  head="$(jq -r '.pull_request.head.ref' "$EVENT")"
  number="$(jq -r '.pull_request.number' "$EVENT")"
  body="$(jq -r '.pull_request.body // ""' "$EVENT")"
  code="$(code_from_branch "$head")"
  [[ -n "$code" ]] || return 0
  story="$(story_by_code "$REPO" "$code" open | cut -d' ' -f2)"
  [[ -n "$story" ]] || { log "PR #${number}: no hay historia abierta ${STORY_PREFIX}-${code}."; return 0; }
  if ! grep -qE "Historia: #${story}\b" <<<"$body"; then
    gh api -X PATCH "repos/${REPO}/pulls/${number}" \
      -f body="$(printf 'Historia: #%s · **%s-%s**\n\n%s' "$story" "$STORY_PREFIX" "$code" "$body")" >/dev/null
    log "PR #${number} enlazado a #${story} (${STORY_PREFIX}-${code})"
  fi
}

# ---------------------------------------------------------------- Router
echo "## Tablero (evento: ${GITHUB_EVENT_NAME}/${action})" >>"$summary"
case "$GITHUB_EVENT_NAME" in
  issues)
    case "$action" in
      opened | reopened) issue_opened ;;
      assigned) issue_assigned ;;
    esac ;;
  issue_comment) [[ "$action" == "created" ]] && issue_comment ;;
  pull_request_target) pr_event ;;
  *) echo "Evento no soportado: ${GITHUB_EVENT_NAME}" ;;
esac
