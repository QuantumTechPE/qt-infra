#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Entrypoint de los runners self-hosted.
# 1. Se autentica en Vault con AppRole (role_id/secret_id locales).
# 2. Lee la credencial de la GitHub App (APP_ID + private key).
# 3. Revoca su token de Vault y delega en /entrypoint.sh de la imagen, que
#    registra un runner EFÍMERO (un job por registro) usando la GitHub App.
# Ningún token personal (PAT) de GitHub es necesario.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${VAULT_ADDR:?}"
APPROLE_DIR=/qt/approle
export VAULT_CACERT="${VAULT_CACERT:-/qt/ca.crt}"

# curl contra Vault validando su certificado TLS con la CA interna
curl() { command curl --cacert "$VAULT_CACERT" "$@"; }

vault_login() {
  local role_id secret_id
  role_id="$(cat "${APPROLE_DIR}/role_id")"
  secret_id="$(cat "${APPROLE_DIR}/secret_id")"
  curl -fsS -X POST "${VAULT_ADDR}/v1/auth/approle/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg r "$role_id" --arg s "$secret_id" '{role_id: $r, secret_id: $s}')" |
    jq -er '.auth.client_token'
}

attempt=0
while true; do
  attempt=$((attempt + 1))
  if [[ -s "${APPROLE_DIR}/role_id" && -s "${APPROLE_DIR}/secret_id" ]] && token="$(vault_login 2>/dev/null)"; then
    if data="$(curl -fsS -H "X-Vault-Token: ${token}" "${VAULT_ADDR}/v1/secret/data/platform/github-app" 2>/dev/null | jq -ec '.data.data')"; then
      break
    fi
    curl -fsS -X POST -H "X-Vault-Token: ${token}" "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
    msg="la GitHub App aún no está en Vault (ejecuta: qt github-app ...)"
  else
    msg="Vault no disponible/sellado o AppRole no inicializado (ejecuta: qt up)"
  fi
  ((attempt == 1 || attempt % 10 == 0)) && echo "[runner] Esperando: ${msg}"
  sleep 15
done

APP_ID="$(jq -r '.app_id' <<<"$data")"
APP_PRIVATE_KEY="$(jq -r '.private_key' <<<"$data")"
export APP_ID APP_PRIVATE_KEY

curl -fsS -X POST -H "X-Vault-Token: ${token}" "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
unset token data
unset -f curl # el entrypoint original habla con GitHub (CA pública), no con Vault

echo "[runner] Credencial de la GitHub App obtenida desde Vault; registrando runner efímero..."
exec /entrypoint.sh "$@"
