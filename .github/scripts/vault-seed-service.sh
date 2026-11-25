#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Crea los secretos iniciales de un microservicio en Vault, uno por ambiente:
#   secret/apps/<servicio>/dev | cert | prod
# a partir de la sección secrets: de su configuración de cada ambiente
# (<dir>/dev.yaml, cert.yaml y prod.yaml, con el formato de qt-config):
#   generate: true   → valor aleatorio DISTINTO por ambiente
#   generate: false  → no se crea; queda listado como pendiente para un admin
# NUNCA sobrescribe: usa check-and-set (cas=0), así que si el secreto ya existe
# no se modifica. Lo usan el workflow "Nuevo microservicio" (token de Vault
# acotado a crear) y el toolbox local (qt new-service). Después, el CICD de
# qt-config agrega las claves nuevas que se declaren con generate: true.
#
#   vault-seed-service.sh <servicio> <dir-con-dev.yaml-cert.yaml-prod.yaml>
# Entradas: VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT (opcional). Requiere: curl, jq, yq, openssl
# -----------------------------------------------------------------------------
set -euo pipefail

service="${1:?servicio}"
dir="${2:?directorio con dev.yaml, cert.yaml y prod.yaml}"
: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
ca=()
[[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")

pending=()
for env in dev cert prod; do
  file="${dir%/}/${env}.yaml"
  path="secret/apps/${service}/${env}"
  [[ -f "$file" ]] || { echo "No existe ${file}" >&2; exit 1; }
  mapfile -t generated < <(yq -r '(.secrets // [])[] | select(.generate == true) | .name' "$file")
  mapfile -t manual < <(yq -r '(.secrets // [])[] | select(.generate != true) | .name' "$file")
  for key in "${manual[@]}"; do pending+=("${env}:${key}"); done
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

if ((${#pending[@]} > 0)); then
  echo
  echo "Pendiente: un admin debe cargar estas claves:"
  for item in "${pending[@]}"; do
    echo "  .\\qt.ps1 secret-set ${service} ${item%%:*} ${item#*:}"
  done
fi
