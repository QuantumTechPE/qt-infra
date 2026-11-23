#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Inicializa y configura Vault de forma IDEMPOTENTE (se puede correr N veces).
#
#   - init (1 key share, uso local/laboratorio) y unseal
#   - KV v2 en secret/ y auditoría a archivo
#   - auth JWT "jwt-github" (OIDC de GitHub Actions) con roles para TODA la
#     organización, atados a los workflows corporativos de qt-infra:
#       gha-ci                 cualquier repo de la org      → secret/ci/*
#       gha-automation         gobierno/tablero/release      → GitHub App
#       gha-promote-<ambiente> promoción GitOps (environment) → GitHub App + Argo CD
#       gha-provision          workflow "Nuevo microservicio" → GitHub App + crear secretos
#   - AppRole para los runners self-hosted
# Los secretos de cada microservicio (secret/apps/<servicio>/<ambiente>) los
# crea service-register.sh al dar de alta el servicio.
# -----------------------------------------------------------------------------
source /scripts/lib.sh

: "${GITHUB_OWNER:?Define GITHUB_OWNER en platform/.env}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
AUDIENCE="${VAULT_AUDIENCE:-qt-vault}"
WF="${GITHUB_OWNER}/${INFRA_REPO}/.github/workflows"

wait_vault

# ------------------------------------------------------------ init / unseal
if [[ "$(vcurl -s "${VAULT_ADDR}/v1/sys/init" | jq -r '.initialized')" != "true" ]]; then
  info "Inicializando Vault"
  umask 077
  vault operator init -key-shares=1 -key-threshold=1 -format=json >"${VAULT_INIT_FILE}.tmp"
  mv "${VAULT_INIT_FILE}.tmp" "$VAULT_INIT_FILE"
  ok "Unseal key y root token guardados en platform/.secrets/vault-init.json (NO versionar)"
fi

if [[ "$(vcurl -s "${VAULT_ADDR}/v1/sys/seal-status" | jq -r '.sealed')" == "true" ]]; then
  info "Desellando Vault"
  vault operator unseal "$(jq -r '.unseal_keys_b64[0]' "$VAULT_INIT_FILE")" >/dev/null
fi
wait_vault_active
vault_root_login
ok "Vault activo en ${VAULT_ADDR} (TLS)"

# ------------------------------------------------------------ engines / audit
if ! vault secrets list -format=json | jq -e '."secret/"' >/dev/null; then
  vault secrets enable -path=secret -version=2 kv >/dev/null
  ok "KV v2 habilitado en secret/"
fi
if ! vault audit list -format=json 2>/dev/null | jq -e '."file/"' >/dev/null; then
  vault audit enable file file_path=/vault/logs/audit.log >/dev/null
  ok "Auditoría habilitada (/vault/logs/audit.log)"
fi

# ------------------------------------------------------------ policies
for f in /policies/*.hcl; do
  vault policy write "$(basename "$f" .hcl)" "$f" >/dev/null
done
for env in "${ENVIRONMENTS[@]}"; do
  vault policy write "promote-${env}" - >/dev/null <<EOF
# Promoción GitOps a ${env}: GitHub App (commit en qt-gitops) + Argo CD (espera)
path "secret/data/platform/github-app" { capabilities = ["read"] }
path "secret/data/platform/argocd/${env}" { capabilities = ["read"] }
EOF
done
ok "Policies cargadas"

# ------------------------------------------------------------ JWT / OIDC GitHub Actions
if ! vault auth list -format=json | jq -e '."jwt-github/"' >/dev/null; then
  vault auth enable -path=jwt-github jwt >/dev/null
fi
vault write auth/jwt-github/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com" >/dev/null

# write_role <nombre> <policies,csv> <string|glob> <bound_claims JSON>
write_role() {
  jq -n --arg aud "$AUDIENCE" --arg pol "$2" --arg type "$3" --argjson claims "$4" '{
    role_type: "jwt",
    user_claim: "repository",
    bound_audiences: [$aud],
    bound_claims_type: $type,
    bound_claims: $claims,
    claim_mappings: { repository: "repository", actor: "actor", workflow: "workflow", ref: "ref", run_id: "run_id", environment: "environment" },
    token_policies: ($pol | split(",")),
    token_ttl: "15m",
    token_max_ttl: "1h"
  }' | vault write "auth/jwt-github/role/$1" - >/dev/null
  ok "Rol JWT $1 → $2"
}

write_role gha-ci "ci-read" string \
  "$(jq -n --arg o "$GITHUB_OWNER" '{repository_owner: $o}')"

write_role gha-automation "automation" string \
  "$(jq -n --arg o "$GITHUB_OWNER" --arg w "$WF" '{
      repository_owner: $o,
      ref: "refs/heads/main",
      job_workflow_ref: [
        "\($w)/service-governance.yml@refs/heads/main",
        "\($w)/service-project.yml@refs/heads/main",
        "\($w)/service-cd.yml@refs/heads/main"
      ]}')"

# Workflow "Nuevo microservicio" (aprobado por admins en el environment provisioning)
write_role gha-provision "automation,provision" string \
  "$(jq -n --arg o "$GITHUB_OWNER" --arg w "$WF" '{
      repository_owner: $o,
      ref: "refs/heads/main",
      environment: "provisioning",
      job_workflow_ref: "\($w)/new-service.yml@refs/heads/main"}')"

for env in "${ENVIRONMENTS[@]}"; do
  write_role "gha-promote-${env}" "promote-${env}" glob \
    "$(jq -n --arg o "$GITHUB_OWNER" --arg w "$WF" --arg e "$env" '{
        repository_owner: $o,
        ref: "refs/heads/main",
        environment: $e,
        job_workflow_ref: "\($w)/_promote.yml@*"}')"
done

# ------------------------------------------------------------ AppRole (runners)
if ! vault auth list -format=json | jq -e '."approle/"' >/dev/null; then
  vault auth enable approle >/dev/null
fi
vault write auth/approle/role/github-runner \
  token_policies=runner token_ttl=5m token_max_ttl=10m \
  secret_id_ttl=0 secret_id_num_uses=0 >/dev/null
mkdir -p "${SECRETS_DIR}/runner-approle"
vault read -field=role_id auth/approle/role/github-runner/role-id >"${SECRETS_DIR}/runner-approle/role_id"
if [[ ! -s "${SECRETS_DIR}/runner-approle/secret_id" ]]; then
  (umask 077; vault write -f -field=secret_id auth/approle/role/github-runner/secret-id >"${SECRETS_DIR}/runner-approle/secret_id")
fi
ok "AppRole github-runner listo"

ok "Vault configurado para la organización ${GITHUB_OWNER} (audiencia OIDC: ${AUDIENCE})"
