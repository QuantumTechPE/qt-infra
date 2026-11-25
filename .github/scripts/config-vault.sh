#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CD de qt-config: conecta los secretos declarados con Vault (HashiCorp).
# Para cada <env>/<servicio>-<env>.yaml revisa secret/apps/<servicio>/<env>:
#   - clave declarada y presente           → OK (el valor NUNCA se lee ni se toca)
#   - falta y generate: true               → la crea con un valor aleatorio
#                                            (distinto por ambiente)
#   - falta y generate: false              → AVISO: la carga un admin con
#                                            qt.ps1 secret-set <servicio> <env> <CLAVE>
# Solo AGREGA claves: un valor existente jamás se sobrescribe. External Secrets
# las inyecta en el pod como variables de entorno.
#
#   config-vault.sh
# Entradas: VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT (opcional), ENVIRONMENT,
#           CONFIG_DIR (checkout de qt-config)
# Requiere: curl, jq, yq, openssl
# -----------------------------------------------------------------------------
set -euo pipefail

: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}" "${ENVIRONMENT:?}"
CONFIG_DIR="${CONFIG_DIR:-.}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
ca=()
[[ -n "${VAULT_CACERT:-}" ]] && ca=(--cacert "$VAULT_CACERT")
vault() { curl -sS "${ca[@]}" -H "X-Vault-Token: ${VAULT_TOKEN}" "$@"; }

echo "## Secretos en Vault (${ENVIRONMENT})" >>"$summary"
echo "| Servicio | Creadas | Pendientes (admin) |" >>"$summary"
echo "|---|---|---|" >>"$summary"
shopt -s nullglob
for f in "$CONFIG_DIR/${ENVIRONMENT}/"*-"${ENVIRONMENT}".yaml; do
  svc="$(basename "$f" "-${ENVIRONMENT}.yaml")"
  mapfile -t declared < <(yq -r '(.secrets // [])[].name' "$f")
  ((${#declared[@]})) || continue
  url="${VAULT_ADDR}/v1/secret/data/apps/${svc}/${ENVIRONMENT}"

  # Claves presentes (solo los NOMBRES: los valores no salen de este proceso)
  code="$(vault -o "$RUNNER_TEMP/vault-get.json" -w '%{http_code}' "$url" 2>/dev/null || true)"
  case "$code" in
    200) mapfile -t present < <(jq -r '.data.data // {} | keys[]' "$RUNNER_TEMP/vault-get.json") ;;
    404) present=() ;;
    *) echo "::error::Vault respondió HTTP ${code} al leer secret/apps/${svc}/${ENVIRONMENT}"; exit 1 ;;
  esac
  rm -f "$RUNNER_TEMP/vault-get.json"

  new="{}" created=() pending=()
  for key in "${declared[@]}"; do
    printf '%s\n' "${present[@]}" | grep -qx "$key" && continue
    if [[ "$(KEY="$key" yq -r '(.secrets // [])[] | select(.name == strenv(KEY)) | .generate // false' "$f")" == "true" ]]; then
      new="$(jq --arg k "$key" --arg v "$(openssl rand -hex 32)" '. + {($k): $v}' <<<"$new")"
      created+=("$key")
    else
      pending+=("$key")
    fi
  done

  if ((${#created[@]})); then
    if [[ "$code" == "404" ]]; then
      # Secreto nuevo: check-and-set 0 (si otro proceso lo creó antes, falla y no pisa nada)
      body="$(jq -n --argjson d "$new" '{options: {cas: 0}, data: $d}')"
      rc="$(vault -o /dev/null -w '%{http_code}' -X POST "$url" -d "$body")"
    else
      # Secreto existente: PATCH agrega solo las claves que faltan
      body="$(jq -n --argjson d "$new" '{data: $d}')"
      rc="$(vault -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/merge-patch+json' "$url" -d "$body")"
    fi
    [[ "$rc" =~ ^20[04]$ ]] || { echo "::error::No se pudieron crear ${created[*]} en secret/apps/${svc}/${ENVIRONMENT} (HTTP ${rc})"; exit 1; }
  fi
  for key in "${pending[@]}"; do
    echo "::warning::${svc}: falta ${key} en Vault (${ENVIRONMENT}). Un admin la carga con: .\\qt.ps1 secret-set ${svc} ${ENVIRONMENT} ${key}"
  done
  echo "| ${svc} | ${created[*]:-—} | ${pending[*]:-—} |" >>"$summary"
done
