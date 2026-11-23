#!/usr/bin/env bash
# Guarda la credencial de la GitHub App de plataforma en Vault y borra la copia
# local de la private key.
#   uso: vault-github-app.sh <APP_ID> <CLIENT_ID>   (la key debe estar en /secrets/github-app.pem)
source /scripts/lib.sh

APP_ID="${1:?APP_ID requerido}"
CLIENT_ID="${2:?CLIENT_ID requerido}"
PEM="${SECRETS_DIR}/github-app.pem"

[[ "$APP_ID" =~ ^[0-9]+$ ]] || die "APP_ID debe ser numérico (Settings → Developer settings → GitHub Apps → App ID)"
[[ -s "$PEM" ]] || die "No se encontró la private key en platform/.secrets/github-app.pem"
grep -q "PRIVATE KEY" "$PEM" || die "github-app.pem no parece una private key PEM"

wait_vault_active
vault_root_login

vault kv put secret/platform/github-app \
  app_id="$APP_ID" client_id="$CLIENT_ID" private_key=@"$PEM" >/dev/null
rm -f "$PEM"
ok "GitHub App ${APP_ID} guardada en secret/platform/github-app (copia local eliminada)"
