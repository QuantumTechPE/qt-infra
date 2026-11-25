#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Pase a producción: issue de pase (uno por release congelado), comandos y
# carriles del tablero.
#
#   pase.sh open                    CD: crea el issue de pase del release
#                                   congelado y reemplaza a los pases anteriores
#   pase.sh lane <issue> <carril> [comentario]
#                                   mueve el pase y sus historias
#   pase.sh command                 issue_comment: /rechazar /agendar /ratificar /revertir
#   pase.sh approve <issue>         tras la aprobación del admin: agenda en Vault
#   pase.sh check-exec              repository_dispatch del agendador: valida y
#                                   entrega lo que se despliega
#   pase.sh executed <issue> ok|fail
#   pase.sh ratified <issue> <tag-final>
#   pase.sh reverted <issue>
#
# Entradas comunes: GH_TOKEN (GitHub App), REPO, PROJECT_OWNER, PROJECT_NUMBER.
# Vault (agenda): VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT. Zona horaria: PASE_TZ.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"
mode="${1:?modo}"
shift
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
SERVICE="${REPO#*/}"
PASE_TZ="${PASE_TZ:-America/Lima}"
server="${GITHUB_SERVER_URL:-https://github.com}"
# Link directo al run actual (aprobación del pase, ejecución, reversión)
run_url="${server}/${REPO}/actions/runs/${GITHUB_RUN_ID:-0}"
log() { echo "$*"; echo "- $*" >>"$summary"; }

# ---------------------------------------------------------------- Vault (agenda)
vault_curl() {
  local ca=()
  [[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")
  curl -fsS "${ca[@]}" -H "X-Vault-Token: ${VAULT_TOKEN:?}" "$@"
}
agenda_url() { echo "${VAULT_ADDR:?}/v1/secret/data/platform/pases/${SERVICE}"; }
agenda_get() { vault_curl "$(agenda_url)" 2>/dev/null | jq -c '.data.data' || echo '{}'; }
agenda_put() { jq -c '{data: .}' <<<"$1" | vault_curl -X POST "$(agenda_url)" -d @- >/dev/null; }
# agenda_state <estado>: cambia el estado de la agenda vigente (si existe)
agenda_state() {
  local cur
  cur="$(agenda_get)"
  [[ "$cur" == "{}" || "$cur" == "null" ]] && return 0
  agenda_put "$(jq -c --arg s "$1" --arg t "$(date -u +%FT%TZ)" '.state = $s | .updated = $t' <<<"$cur")"
}

# ---------------------------------------------------------------- Pase
pase_url() { echo "${server}/${REPO}/issues/$1"; }

# move_all <issue> <carril>: pase + historias del pase
move_all() {
  local issue="$1" lane="$2" data n
  data="$(pase_data "$REPO" "$issue")"
  set_status "$(issue_node "$REPO" "$issue")" "$lane"
  for n in $(jq -r '.stories[].issue' <<<"$data"); do
    set_status "$(issue_node "$REPO" "$n")" "$lane"
  done
  log "Pase #${issue} y sus historias → **${lane}**"
}

open_pase() {
  : "${TAG:?}" "${IMAGE:?}" "${DIGEST:?}" "${COMMIT:?}"
  local stories_json="[]" code n title data issue body old
  for code in ${STORIES:-}; do
    read -r _ n title <<<"$(story_by_code "$REPO" "$code" open)" || true
    [[ -z "${n:-}" ]] && continue
    stories_json="$(jq -c --arg c "${STORY_PREFIX}-${code}" --argjson n "$n" --arg t "$title" \
      '. + [{code: $c, issue: $n, title: $t}]' <<<"$stories_json")"
  done
  data="$(jq -nc --arg tag "$TAG" --arg version "${VERSION:-}" --arg image "$IMAGE" --arg digest "$DIGEST" \
    --arg commit "$COMMIT" --arg rtag "${REV_TAG:-}" --arg rimage "${REV_IMAGE:-}" --arg rdigest "${REV_DIGEST:-}" \
    --arg rcommit "${REV_COMMIT:-}" --arg rlabel "${REV_LABEL:-}" --argjson stories "$stories_json" '{
      tag: $tag, version: $version, image: $image, digest: $digest, commit: $commit,
      reversion: {tag: $rtag, image: $rimage, digest: $rdigest, commit: $rcommit, label: $rlabel},
      stories: $stories}')"

  body="$(cat <<EOF
## Pase a producción · \`${SERVICE}\` ${TAG}

| | |
|---|---|
| Release del cambio | [\`${TAG}\`](${server}/${REPO}/releases/tag/${TAG}) |
| Release de reversión | [\`${REV_TAG}\`](${server}/${REPO}/releases/tag/${REV_TAG}) → restaura **${REV_LABEL}** |
| Imagen | \`${IMAGE}@${DIGEST}\` |

### Historias
$(jq -r 'if length == 0 then "- (sin historias)" else .[] | "- #\(.issue)" end' <<<"$stories_json")

### Comandos (comenta en este issue)
| Comando | Cuándo | Quién |
|---|---|---|
| \`/rechazar <motivo>\` | Pruebas QA (antes de ejecutar el pase) | QA |
| \`/agendar AAAA-MM-DD HH:MM\` | QA conforme. Hora de ${PASE_TZ} | Líder; **lo aprueba un admin** |
| \`/ratificar\` | Ratificación producción | Usuario / QA |
| \`/revertir <motivo>\` | Ratificación producción o Done | **Admins** |

<!-- qt-pase ${data} -->
EOF
)"

  issue="$(gh api "repos/${REPO}/issues?labels=${PASE_LABEL}&state=open&per_page=100" \
    --jq ".[] | select(.title | contains(\"${TAG}\")) | .number" | head -n1)"
  if [[ -n "$issue" ]]; then
    gh api -X PATCH "repos/${REPO}/issues/${issue}" -f body="$body" >/dev/null
  else
    issue="$(gh api -X POST "repos/${REPO}/issues" -f title="[PASE] ${SERVICE} ${TAG}" -f body="$body" \
      -f "labels[]=${PASE_LABEL}" --jq '.number')"
  fi

  # Un congelamiento nuevo reemplaza a los pases aún no ejecutados
  for old in $(gh api "repos/${REPO}/issues?labels=${PASE_LABEL}&state=open&per_page=100" --jq '.[].number'); do
    [[ "$old" == "$issue" ]] && continue
    comment "$REPO" "$old" "♻️ Reemplazado por #${issue} (${TAG}): un nuevo congelamiento incluye estos cambios. Su agenda, si la había, queda sin efecto."
    gh api -X PATCH "repos/${REPO}/issues/${old}" -f state=closed -f state_reason=not_planned >/dev/null
    log "Pase #${old} reemplazado por #${issue}"
  done

  load_project
  set_text "$(issue_node "$REPO" "$issue")" "Versión" "$TAG"
  for n in $(jq -r '.[].issue' <<<"$stories_json"); do
    set_text "$(issue_node "$REPO" "$n")" "Versión" "$TAG"
  done
  move_all "$issue" "Congelamiento (doing)"
  echo "issue=${issue}" >>"$out"
  log "Issue de pase: $(pase_url "$issue")"
}

# ---------------------------------------------------------------- Comandos
command_pase() {
  local event="${GITHUB_EVENT_PATH:?}" body issue user perm lane cmd arg data
  body="$(jq -r '.comment.body' "$event" | tr -d '\r' | head -n1)"
  issue="$(jq -r '.issue.number' "$event")"
  user="$(jq -r '.comment.user.login' "$event")"
  cmd="$(sed -nE 's#^/([a-z]+).*#\1#p' <<<"$body")"
  arg="$(sed -E 's#^/[a-z]+[[:space:]]*##' <<<"$body")"
  echo "issue=${issue}" >>"$out"
  [[ "$(jq -r '.issue.state' "$event")" == "open" ]] || { comment "$REPO" "$issue" "ℹ️ Este pase está cerrado."; return 0; }

  perm="$(permission "$REPO" "$user")"
  load_project
  lane="$(current_status "$(issue_node "$REPO" "$issue")")"
  deny() { comment "$REPO" "$issue" "⛔ $1"; log "denegado: $1"; }

  case "$cmd" in
    rechazar)
      in_list "$perm" admin maintain write triage || { deny "@${user} no tiene permisos para rechazar."; return 0; }
      in_list "$lane" "Congelamiento (done)" "Pruebas QA" "Gestión de pase" ||
        { deny "\`/rechazar\` aplica en Pruebas QA o Gestión de pase (ahora: ${lane:-sin carril})."; return 0; }
      [[ -n "${VAULT_TOKEN:-}" ]] && agenda_state cancelado
      data="$(pase_data "$REPO" "$issue")"
      move_all "$issue" "Rechazo QA"
      local n code msg="" t
      for n in $(jq -r '.stories[].issue' <<<"$data"); do
        code="$(jq -r --argjson n "$n" '.stories[] | select(.issue == $n) | .code | sub("^[A-Z]+-"; "")' <<<"$data")"
        msg+=$'\n'"- #${n}: $(recreate_branch "$REPO" "$n" "$code")"
        comment "$REPO" "$n" "❌ **Rechazo QA** (pase #${issue}) por @${user}: ${arg:-sin motivo}. Corrige en \`qt/${code}\` y abre un PR nuevo."
      done
      for t in "$(jq -r '.tag' <<<"$data")" "$(jq -r '.reversion.tag' <<<"$data")"; do
        gh release edit "$t" --repo "$REPO" --title "${t} · RECHAZADO" >/dev/null 2>&1 || true
      done
      comment "$REPO" "$issue" "❌ **Rechazado en QA** por @${user}: ${arg:-sin motivo}. Releases marcados como rechazados; QA vuelve a **$(jq -r '.reversion.label' <<<"$data")** (CICD QA REV). Ramas para corregir:${msg}"
      gh api -X PATCH "repos/${REPO}/issues/${issue}" -f state=closed -f state_reason=not_planned >/dev/null
      # Reversión QA: QA vuelve a lo que corre en producción (release de reversión)
      {
        echo "cmd=rechazar"
        echo "image=$(jq -r '.reversion.image' <<<"$data")"
        echo "digest=$(jq -r '.reversion.digest' <<<"$data")"
        echo "commit=$(jq -r '.reversion.commit' <<<"$data")"
        echo "label=$(jq -r '.reversion.label' <<<"$data")"
      } >>"$out"
      ;;

    agendar)
      in_list "$perm" admin maintain write || { deny "@${user} no tiene permisos para agendar."; return 0; }
      # También en "Ejecución de pase" si la ejecución se cortó ANTES de desplegar
      # (p. ej. una caída de GitHub): la agenda no llegó a "ejecutado".
      if ! in_list "$lane" "Congelamiento (done)" "Pruebas QA" "Gestión de pase"; then
        if [[ "$lane" != "Ejecución de pase" || -z "${VAULT_TOKEN:-}" ]] ||
          [[ "$(jq -r '.state // ""' <<<"$(agenda_get)")" == "ejecutado" ]]; then
          deny "\`/agendar\` aplica tras el congelamiento (ahora: ${lane:-sin carril})."
          return 0
        fi
      fi
      [[ "$arg" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2})$ ]] ||
        { deny "Formato: \`/agendar AAAA-MM-DD HH:MM\` (hora de ${PASE_TZ})."; return 0; }
      local when epoch
      when="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
      epoch="$(TZ="$PASE_TZ" date -d "$when" +%s 2>/dev/null)" || { deny "Fecha inválida: ${when}"; return 0; }
      ((epoch > $(date +%s) + 300)) || { deny "La fecha debe ser al menos 5 minutos en el futuro (${PASE_TZ})."; return 0; }
      [[ -n "${VAULT_TOKEN:-}" ]] && agenda_state reprogramado # anula la aprobación anterior
      move_all "$issue" "Gestión de pase"
      set_text "$(issue_node "$REPO" "$issue")" "Pase" "${when} (${PASE_TZ})"
      comment "$REPO" "$issue" "📅 @${user} solicita el pase para **${when}** (${PASE_TZ}). Falta la **aprobación de un admin**: 👉 [**Aprobar el pase**](${run_url}) → *Review deployments* → \`pase-produccion\` → *Approve and deploy*."
      {
        echo "cmd=agendar"
        echo "when=${when}"
        echo "epoch=${epoch}"
        echo "requested_by=${user}"
      } >>"$out"
      ;;

    ratificar)
      in_list "$perm" admin maintain write triage || { deny "@${user} no tiene permisos para ratificar."; return 0; }
      [[ "$lane" == "Ratificación producción" ]] ||
        { deny "\`/ratificar\` aplica en Ratificación producción (ahora: ${lane:-sin carril})."; return 0; }
      echo "cmd=ratificar" >>"$out"
      echo "tag=$(jq -r '.tag' <<<"$(pase_data "$REPO" "$issue")")" >>"$out"
      ;;

    revertir)
      [[ "$perm" == "admin" ]] || { deny "Solo un admin puede revertir producción (@${user}: ${perm})."; return 0; }
      in_list "$lane" "Ejecución de pase" "Ratificación producción" "Done" ||
        { deny "\`/revertir\` aplica con el pase en producción (ahora: ${lane:-sin carril})."; return 0; }
      data="$(pase_data "$REPO" "$issue")"
      move_all "$issue" "Rechazo producción"
      comment "$REPO" "$issue" "⏪ @${user} revierte producción: ${arg:-sin motivo}. Desplegando \`$(jq -r '.reversion.tag' <<<"$data")\` (restaura **$(jq -r '.reversion.label' <<<"$data")**)… 👉 [Ver CICD PROD REV](${run_url})"
      {
        echo "cmd=revertir"
        echo "image=$(jq -r '.reversion.image' <<<"$data")"
        echo "digest=$(jq -r '.reversion.digest' <<<"$data")"
        echo "commit=$(jq -r '.reversion.commit' <<<"$data")"
        echo "label=$(jq -r '.reversion.label' <<<"$data")"
      } >>"$out"
      ;;

    *) log "Comentario sin comando de pase: se ignora." ;;
  esac
}

# Tras la aprobación del admin (environment pase-produccion): agenda en Vault
approve() {
  local issue="${1:?}" data approver
  : "${EPOCH:?}" "${WHEN:?}"
  data="$(pase_data "$REPO" "$issue")"
  approver="${APPROVER:-admin}"
  agenda_put "$(jq -nc --arg repo "$REPO" --argjson issue "$issue" --arg tag "$(jq -r .tag <<<"$data")" \
    --argjson epoch "$EPOCH" --arg when "$WHEN" --arg tz "$PASE_TZ" --arg by "$approver" \
    --arg requested "${REQUESTED_BY:-}" --arg at "$(date -u +%FT%TZ)" '{
      repo: $repo, issue: $issue, tag: $tag, epoch: $epoch, when: $when, tz: $tz,
      requested_by: $requested, approved_by: $by, approved_at: $at, state: "aprobado"}')"
  comment "$REPO" "$issue" "✅ Pase **aprobado** por @${approver}. Se ejecutará automáticamente el **${WHEN}** (${PASE_TZ})."
  log "Pase #${issue} agendado: ${WHEN} (${PASE_TZ})"
}

# repository_dispatch del agendador: valida contra Vault y entrega el despliegue
check_exec() {
  local event="${GITHUB_EVENT_PATH:?}" tag issue agenda data
  tag="$(jq -r '.client_payload.tag' "$event")"
  issue="$(jq -r '.client_payload.issue' "$event")"
  agenda="$(agenda_get)"
  fail() { echo "::error::$1"; [[ -n "$issue" && "$issue" != "null" ]] && comment "$REPO" "$issue" "⛔ No se ejecuta el pase: $1"; exit 1; }
  [[ "$(jq -r '.tag // ""' <<<"$agenda")" == "$tag" ]] || fail "la agenda vigente no corresponde a ${tag}."
  # "ejecutando": reintento de una ejecución que se cortó antes de desplegar
  # (desplegar el mismo digest otra vez es idempotente).
  in_list "$(jq -r '.state' <<<"$agenda")" aprobado despachado ejecutando || fail "la agenda no está aprobada ($(jq -r '.state' <<<"$agenda"))."
  (($(date +%s) >= $(jq -r '.epoch' <<<"$agenda"))) || fail "aún no es la hora agendada ($(jq -r '.when' <<<"$agenda"))."
  [[ "$(gh api "repos/${REPO}/issues/${issue}" --jq '.state')" == "open" ]] || fail "el issue de pase #${issue} está cerrado."
  data="$(pase_data "$REPO" "$issue")"
  [[ "$(jq -r '.tag' <<<"$data")" == "$tag" ]] || fail "el issue #${issue} no es el pase de ${tag}."
  agenda_state ejecutando
  # El tablero y el comentario son informativos: si GitHub falla aun con los
  # reintentos, el pase aprobado se ejecuta igual.
  (load_project && move_all "$issue" "Ejecución de pase") ||
    echo "::warning::No se pudo mover el tablero a 'Ejecución de pase'; el pase continúa."
  comment "$REPO" "$issue" "🚀 **Ejecutando el pase** ${tag} a producción (agendado para $(jq -r '.when' <<<"$agenda"), aprobado por @$(jq -r '.approved_by' <<<"$agenda")). 👉 [Ver CICD PROD](${run_url})" ||
    echo "::warning::No se pudo comentar en el pase #${issue}; el pase continúa."
  {
    echo "issue=${issue}"
    echo "tag=${tag}"
    echo "image=$(jq -r '.image' <<<"$data")"
    echo "digest=$(jq -r '.digest' <<<"$data")"
    echo "commit=$(jq -r '.commit' <<<"$data")"
  } >>"$out"
}

executed() {
  local issue="${1:?}" result="${2:?ok|fail}"
  load_project
  if [[ "$result" == "ok" ]]; then
    [[ -n "${VAULT_TOKEN:-}" ]] && agenda_state ejecutado
    move_all "$issue" "Ratificación producción"
    comment "$REPO" "$issue" "🟢 **Pase ejecutado** ([CICD PROD](${run_url})): producción está *Healthy*. Valida y comenta \`/ratificar\`, o \`/revertir <motivo>\` (admins)."
  else
    [[ -n "${VAULT_TOKEN:-}" ]] && agenda_state fallido
    move_all "$issue" "Reversión"
    comment "$REPO" "$issue" "🔴 **El pase falló**: Argo CD no quedó *Healthy* y el pipeline restauró la versión anterior (rollback GitOps). 👉 [Ver CICD PROD](${run_url})"
  fi
}

ratified() {
  local issue="${1:?}" final="${2:?}" data n
  data="$(pase_data "$REPO" "$issue")"
  load_project
  move_all "$issue" "Done"
  for n in $(jq -r '.stories[].issue' <<<"$data") "$issue"; do
    set_text "$(issue_node "$REPO" "$n")" "Versión" "$final"
  done
  for n in $(jq -r '.stories[].issue' <<<"$data"); do
    comment "$REPO" "$n" "✅ **En producción** con [${final}](${server}/${REPO}/releases/tag/${final}) (pase #${issue})."
    gh api -X PATCH "repos/${REPO}/issues/${n}" -f state=closed -f state_reason=completed >/dev/null
  done
  comment "$REPO" "$issue" "🏁 **Ratificado**. Release final: [${final}](${server}/${REPO}/releases/tag/${final})."
  gh api -X PATCH "repos/${REPO}/issues/${issue}" -f state=closed -f state_reason=completed >/dev/null
}

reverted() {
  local issue="${1:?}" data n code msg=""
  data="$(pase_data "$REPO" "$issue")"
  load_project
  move_all "$issue" "Reversión"
  for n in $(jq -r '.stories[].issue' <<<"$data"); do
    code="$(jq -r --argjson n "$n" '.stories[] | select(.issue == $n) | .code | sub("^[A-Z]+-"; "")' <<<"$data")"
    gh api -X PATCH "repos/${REPO}/issues/${n}" -f state=open >/dev/null
    msg+=$'\n'"- #${n}: $(recreate_branch "$REPO" "$n" "$code")"
    comment "$REPO" "$n" "⏪ **Revertido en producción** (pase #${issue}). El cambio sigue en \`master\`: corrige en \`qt/${code}\` (o revierte el código) antes del próximo congelamiento."
  done
  gh release edit "$(jq -r '.tag' <<<"$data")" --repo "$REPO" --title "$(jq -r '.tag' <<<"$data") · REVERTIDO" >/dev/null 2>&1 || true
  comment "$REPO" "$issue" "⏪ **Reversión completada**: producción ejecuta **$(jq -r '.reversion.label' <<<"$data")**. Ramas para corregir:${msg}"
  gh api -X PATCH "repos/${REPO}/issues/${issue}" -f state=closed -f state_reason=not_planned >/dev/null
}

case "$mode" in
  open) open_pase ;;
  lane)
    load_project
    move_all "${1:?issue}" "${2:?carril}"
    if [[ -n "${3:-}" ]]; then comment "$REPO" "$1" "$3"; fi
    ;;
  command) command_pase ;;
  approve) approve "$@" ;;
  check-exec) check_exec ;;
  executed) executed "$@" ;;
  ratified) ratified "$@" ;;
  reverted) reverted "$@" ;;
  *) echo "Modo desconocido: $mode" >&2; exit 2 ;;
esac
