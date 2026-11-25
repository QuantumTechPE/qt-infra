#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Administración de secretos de un microservicio por ambiente (solo admins):
#   service-secret.sh list <servicio> <dev|cert|prod>          nombres de las claves (nunca valores)
#   service-secret.sh set  <servicio> <dev|cert|prod> <CLAVE>  lee el valor por stdin
#   service-secret.sh generate <servicio> <dev|cert|prod> <CLAVE>  valor aleatorio (rotación)
# Ruta: secret/apps/<servicio>/<ambiente>. External Secrets lo sincroniza al
# clúster del ambiente en ≤ 15 min; los pods lo toman en su próximo reinicio.
# -----------------------------------------------------------------------------
source /scripts/lib.sh

action="${1:?list | set | generate}"
service="${2:?servicio}"
env="${3:?ambiente}"
valid_env "$env"
[[ "$service" =~ ^[a-z][a-z0-9-]+$ ]] || die "Servicio inválido: ${service}"
path="secret/apps/${service}/${env}"

wait_vault_active
vault_root_login

write_key() {
  local key="$1" value="$2"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "La clave debe ser una variable de entorno válida (MAYÚSCULAS_CON_GUIONES_BAJOS): ${key}"
  [[ -n "$value" ]] || die "Valor vacío"
  if vault kv get "$path" >/dev/null 2>&1; then
    printf '%s' "$value" | vault kv patch "$path" "${key}=-" >/dev/null
  else
    printf '%s' "$value" | vault kv put "$path" "${key}=-" >/dev/null
  fi
  ok "${path}: ${key} actualizado (External Secrets lo sincroniza en ≤ 15 min)"
}

case "$action" in
  list)
    if vault kv get -format=json "$path" >/tmp/secret.json 2>/dev/null; then
      echo "Claves en ${path} (versión $(jq -r '.data.metadata.version' /tmp/secret.json)):"
      jq -r '.data.data | keys[] | "  - " + .' /tmp/secret.json
      rm -f /tmp/secret.json
    else
      warn "${path} no existe todavía"
    fi
    ;;
  set)
    key="${4:?CLAVE}"
    IFS= read -r value || true
    write_key "$key" "$value"
    ;;
  generate)
    key="${4:?CLAVE}"
    write_key "$key" "$(openssl rand -hex 32)"
    ;;
  *) die "Acción desconocida: ${action}" ;;
esac
