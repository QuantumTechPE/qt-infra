#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Despertador local de los agendadores de qt-infra (servicio pase-ticker del compose).
#
# Los cron de GitHub ("*/5 * * * *") son "best effort": en la práctica pueden
# correr con HORAS de atraso. Este bucle corre en el host de la plataforma y
# despierta a los workflows de qt-infra con repository_dispatch:
#
#   pase-agenda    cada PASE_TICK_SECONDS lee la agenda de Vault (solo lectura,
#                  AppRole pase-ticker). Si un pase APROBADO llegó a su hora,
#                  despierta a "Auto · Agendador de pases" (pases.yml).
#   ramas-al-dia   cada RAMAS_AL_DIA_SECONDS despierta a "Auto · Ramas al día"
#                  (PRs aprobados atrasados respecto a master).
#
# La validación, el despacho y los cambios de estado siguen en esos workflows
# (con OIDC), igual que con el cron, que queda de respaldo.
# -----------------------------------------------------------------------------
set -uo pipefail
# shellcheck source=lib.sh
source /scripts/lib.sh
: "${VAULT_ADDR:?}" "${GITHUB_OWNER:?}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
TICK="${PASE_TICK_SECONDS:-60}"
# Mientras siga "aprobado" (p. ej. el workflow falló), vuelve a despertar cada 5 min
RETRIGGER="${PASE_RETRIGGER_SECONDS:-300}"
# 0 desactiva el disparo de "Ramas al día"
RAMAS_EVERY="${RAMAS_AL_DIA_SECONDS:-300}"
APPROLE_DIR="${APPROLE_DIR:-/qt/approle}"
GITHUB_API="https://api.github.com"
declare -A last=()
last_ramas=0

log() { echo "[pase-ticker] $(date -u +%FT%TZ) $*"; }

vault_login() {
  vcurl -fsS -X POST "${VAULT_ADDR}/v1/auth/approle/login" \
    -d "$(jq -nc --arg r "$(cat "${APPROLE_DIR}/role_id")" --arg s "$(cat "${APPROLE_DIR}/secret_id")" \
      '{role_id: $r, secret_id: $s}')" | jq -er '.auth.client_token'
}
vget() { vcurl -fsS -H "X-Vault-Token: ${token}" "$@"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# Token de instalación de la GitHub App acotado a qt-infra (contents: write)
app_token() {
  local data app_id key now h p s jwt inst
  data="$(vget "${VAULT_ADDR}/v1/secret/data/platform/github-app" | jq -c '.data.data')" || return 1
  app_id="$(jq -r .app_id <<<"$data")"
  key="$(jq -r .private_key <<<"$data")"
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign <(printf '%s\n' "$key") | b64url)
  jwt="$h.$p.$s"
  inst="$(curl -fsS -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${GITHUB_OWNER}/${INFRA_REPO}/installation" | jq -er .id)" || return 1
  curl -fsS -X POST -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/app/installations/${inst}/access_tokens" \
    -d "$(jq -nc --arg r "$INFRA_REPO" '{repositories: [$r], permissions: {contents: "write"}}')" |
    jq -er .token
}

# dispatch <event_type>: repository_dispatch a qt-infra (token de la App por llamada)
dispatch() {
  local gh_token rc
  gh_token="$(app_token 2>/dev/null)" || return 1
  curl -fsS -X POST -H "Authorization: Bearer ${gh_token}" -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${GITHUB_OWNER}/${INFRA_REPO}/dispatches" \
    -d "$(jq -nc --arg e "$1" '{event_type: $e}')" >/dev/null
  rc=$?
  unset gh_token
  return "$rc"
}

log "vigilando la agenda de pases cada ${TICK}s y Ramas al día cada ${RAMAS_EVERY}s → ${GITHUB_OWNER}/${INFRA_REPO}"
while true; do
  sleep "$TICK"
  # Vault sellado o AppRole aún sin inicializar (qt up): se reintenta en el siguiente tick
  [[ -s "${APPROLE_DIR}/role_id" && -s "${APPROLE_DIR}/secret_id" ]] || continue
  token="$(vault_login 2>/dev/null)" || continue

  now=$(date +%s)
  due=()
  for svc in $(vget -X LIST "${VAULT_ADDR}/v1/secret/metadata/platform/pases" 2>/dev/null | jq -r '.data.keys[]?'); do
    agenda="$(vget "${VAULT_ADDR}/v1/secret/data/platform/pases/${svc}" 2>/dev/null | jq -c '.data.data')" || continue
    [[ "$(jq -r '.state' <<<"$agenda")" == "aprobado" ]] || continue
    (( now >= $(jq -r '.epoch // 0' <<<"$agenda") )) || continue
    key="${svc}@$(jq -r '.tag' <<<"$agenda")"
    (( now - ${last[$key]:-0} >= RETRIGGER )) || continue
    due+=("$key")
  done

  if ((${#due[@]})); then
    if dispatch pase-agenda; then
      for k in "${due[@]}"; do last[$k]=$now; done
      log "en hora: ${due[*]} → agendador de pases despertado"
    else
      log "no se pudo despertar al agendador de pases (${due[*]}); se reintenta en ${TICK}s"
    fi
  fi

  if ((RAMAS_EVERY > 0 && now - last_ramas >= RAMAS_EVERY)); then
    if dispatch ramas-al-dia; then
      last_ramas=$now
    else
      log "no se pudo despertar a Ramas al día; se reintenta en ${TICK}s"
    fi
  fi

  vcurl -fsS -X POST -H "X-Vault-Token: ${token}" "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  unset token
done
