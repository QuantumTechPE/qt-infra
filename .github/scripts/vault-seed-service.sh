#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Crea los secretos iniciales de un microservicio en Vault, uno por ambiente:
#   secret/apps/<servicio>/dev | qa | prod
# a partir de deploy/vault/secrets.yaml:
#   generate: true   → valor aleatorio DISTINTO por ambiente
#   generate: false  → no se crea; queda listado como pendiente para un admin
# NUNCA sobrescribe: usa check-and-set (cas=0), así que si el secreto ya existe
# no se modifica. Lo usan el workflow "Nuevo microservicio" (token de Vault
# acotado a crear) y el toolbox local (qt new-service).
#
#   vault-seed-service.sh <servicio> <ruta/a/secrets.yaml>
# Entradas: VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT (opcional). Requiere: curl, jq, yq, openssl
# -----------------------------------------------------------------------------
set -euo pipefail

service="${1:?servicio}"
secrets_file="${2:?ruta a deploy/vault/secrets.yaml}"
: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
ca=()
[[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")

[[ -f "$secrets_file" ]] || { echo "No existe ${secrets_file}" >&2; exit 1; }
mapfile -t generated < <(yq '(.keys // [])[] | select(.generate == true) | .name' "$secrets_file")
mapfile -t manual < <(yq '(.keys // [])[] | select(.generate != true) | .name' "$secrets_file")

if ((${#generated[@]} == 0 && ${#manual[@]} == 0)); then
  echo "✔ ${service} no declara secretos (deploy/vault/secrets.yaml)"
  exit 0
fi

for env in dev qa prod; do
  path="secret/apps/${service}/${env}"
  if ((${#generated[@]} == 0)); then
    echo "• ${path}: sin claves autogeneradas"
    continue
  fi
  data="{}"
  for key in "${generated[@]}"; do
    data="$(jq --arg k "$key" --arg v "$(openssl rand -hex 32)" '. + {($k): $v}' <<<"$data")"
  done
  body="$(jq -n --argjson d "$data" '{options: {cas: 0}, data: $d}')"
  code="$(curl -s "${ca[@]}" -o /tmp/vault-seed.out -w '%{http_code}' \
    -H "X-Vault-Token: ${VAULT_TOKEN}" -X POST "${VAULT_ADDR}/v1/secret/data/apps/${service}/${env}" -d "$body")"
  case "$code" in
    200 | 204) echo "✔ ${path}: creado (${generated[*]})" ;;
    400 | 403) echo "• ${path}: ya existe, no se modifica" ;;
    *) echo "✖ ${path}: HTTP ${code} $(cat /tmp/vault-seed.out)" >&2; exit 1 ;;
  esac
done
rm -f /tmp/vault-seed.out

if ((${#manual[@]} > 0)); then
  echo
  echo "Pendiente: un admin debe cargar estas claves en cada ambiente (dev, qa, prod):"
  for key in "${manual[@]}"; do
    echo "  .\\qt.ps1 secret-set ${service} <dev|qa|prod> ${key}"
  done
fi
