#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Agendador de pases a producción (lo ejecuta qt-infra cada 5 minutos).
#
# Lee la agenda en Vault (secret/platform/pases/<servicio>, escrita SOLO tras
# la aprobación de un admin) y, para cada pase aprobado cuya hora llegó, envía
# un repository_dispatch "pase-ejecutar" al repo del servicio. El workflow del
# servicio vuelve a validar todo contra Vault antes de desplegar.
#
# Entradas: GH_TOKEN (GitHub App de la organización), VAULT_ADDR, VAULT_TOKEN,
#           VAULT_CACERT
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
ca=()
[[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")
vault() { curl -fsS "${ca[@]}" -H "X-Vault-Token: ${VAULT_TOKEN}" "$@"; }

now="$(date +%s)"
echo "## Agendador de pases ($(date -u +%FT%TZ))" >>"$summary"
services="$(vault -X LIST "${VAULT_ADDR}/v1/secret/metadata/platform/pases" 2>/dev/null | jq -r '.data.keys[]?' || true)"
if [[ -z "$services" ]]; then
  echo "- Sin pases agendados." >>"$summary"
  exit 0
fi

for svc in $services; do
  agenda="$(vault "${VAULT_ADDR}/v1/secret/data/platform/pases/${svc}" | jq -c '.data.data')"
  state="$(jq -r '.state' <<<"$agenda")"
  epoch="$(jq -r '.epoch' <<<"$agenda")"
  line="\`${svc}\` $(jq -r '.tag' <<<"$agenda") · $(jq -r '.when' <<<"$agenda") ($(jq -r '.tz' <<<"$agenda")) · ${state}"
  if [[ "$state" != "aprobado" ]] || ((now < epoch)); then
    echo "- ${line}" >>"$summary"
    continue
  fi
  repo="$(jq -r '.repo' <<<"$agenda")"
  jq -nc --arg tag "$(jq -r '.tag' <<<"$agenda")" --argjson issue "$(jq -r '.issue' <<<"$agenda")" \
    '{event_type: "pase-ejecutar", client_payload: {tag: $tag, issue: $issue}}' |
    gh api -X POST "repos/${repo}/dispatches" --input - >/dev/null
  jq -c --arg t "$(date -u +%FT%TZ)" '{data: (.state = "despachado" | .dispatched_at = $t)}' <<<"$agenda" |
    vault -X POST "${VAULT_ADDR}/v1/secret/data/platform/pases/${svc}" -d @- >/dev/null
  echo "- 🚀 ${line} → **despachado**" | tee -a "$summary"
done
