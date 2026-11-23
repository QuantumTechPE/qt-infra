#!/usr/bin/env bash
# Utilidades compartidas por los scripts de la plataforma (corren en el toolbox).
set -euo pipefail

export VAULT_ADDR="${VAULT_ADDR:-https://vault:8200}"
SECRETS_DIR="${SECRETS_DIR:-/secrets}"
TLS_DIR="${SECRETS_DIR}/tls"
export VAULT_CACERT="${VAULT_CACERT:-${TLS_DIR}/ca.crt}"
VAULT_INIT_FILE="${SECRETS_DIR}/vault-init.json"
ENVIRONMENTS=(dev qa prod)

info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# curl contra Vault validando su certificado con la CA interna
vcurl() { curl --cacert "$VAULT_CACERT" "$@"; }

# Contraseña aleatoria que cumple políticas de complejidad (SonarQube, D-Track).
gen_password() { printf '%s#Aa1' "$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-24)"; }

# Espera a que Vault responda (aunque esté sellado o sin inicializar).
wait_vault() {
  for _ in $(seq 1 60); do
    vcurl -s -o /dev/null "${VAULT_ADDR}/v1/sys/health" && return 0
    sleep 2
  done
  die "Vault no responde en ${VAULT_ADDR}"
}

# Espera a que Vault esté desellado y activo (HTTP 200 en /sys/health).
wait_vault_active() {
  for _ in $(seq 1 60); do
    [[ "$(vcurl -s -o /dev/null -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health")" == "200" ]] && return 0
    sleep 2
  done
  die "Vault no quedó activo (¿sellado?)"
}

# Exporta VAULT_TOKEN con el root token local (solo para bootstrap).
vault_root_login() {
  [[ -s "$VAULT_INIT_FILE" ]] || die "Vault no está inicializado. Ejecuta: qt up"
  VAULT_TOKEN="$(jq -r '.root_token' "$VAULT_INIT_FILE")"
  export VAULT_TOKEN
}

valid_env() {
  [[ " ${ENVIRONMENTS[*]} " == *" $1 "* ]] || die "Ambiente inválido: '$1' (dev | qa | prod)"
}

# Dominio del Ingress de un ambiente:
#   INGRESS_DOMAIN_<AMBIENTE> > ingress_domain del inventario > <IP 1er control-plane>.nip.io
ingress_domain() {
  local env="$1" var="INGRESS_DOMAIN_${1^^}"
  if [[ -n "${!var:-}" ]]; then
    echo "${!var}"
    return
  fi
  yq e '.all.vars.ingress_domain // ((.all.children.k3s_server.hosts | to_entries | .[0].value.ansible_host) + ".nip.io")' \
    "/k8s/provisioning/inventories/${env}/hosts.yml"
}

# ":<puerto>" del Ingress si no es el 80 (clústeres locales k3d: INGRESS_PORT_<AMBIENTE>)
ingress_port() {
  local var="INGRESS_PORT_${1^^}"
  [[ -n "${!var:-}" && "${!var}" != "80" ]] && echo ":${!var}" || true
}

# Primer host declarado en PLATFORM_HOST (lo usan los clústeres para llegar a Vault)
platform_host() {
  : "${PLATFORM_HOST:?Define PLATFORM_HOST en platform/.env (IP o DNS de esta máquina en la LAN)}"
  echo "${PLATFORM_HOST%%,*}"
}
