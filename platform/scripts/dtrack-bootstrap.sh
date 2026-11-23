#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configura OWASP Dependency-Track (equivalente libre a JFrog Xray):
#   - reemplaza la contraseña por defecto (guardada en Vault)
#   - da permisos de carga de SBOM al team "Automation"
#   - emite una API key para CI y la guarda en Vault
# -----------------------------------------------------------------------------
source /scripts/lib.sh

DT="${DTRACK_URL:-http://dtrack-apiserver:8080}"

info "Esperando Dependency-Track (el primer arranque descarga la base de CVEs y tarda varios minutos)"
for _ in $(seq 1 120); do
  curl -fsS "${DT}/api/version" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "${DT}/api/version" >/dev/null || die "Dependency-Track no responde"

wait_vault_active
vault_root_login

password="$(vault kv get -field=password secret/platform/dependency-track-admin 2>/dev/null || true)"
if [[ -z "$password" ]]; then
  info "Reemplazando la contraseña por defecto de admin"
  password="$(gen_password)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${DT}/api/v1/user/forceChangePassword" \
    --data-urlencode username=admin --data-urlencode password=admin \
    --data-urlencode "newPassword=${password}" --data-urlencode "confirmPassword=${password}")"
  [[ "$code" == "200" ]] || die "No se pudo cambiar la contraseña por defecto (HTTP ${code})"
  vault kv put secret/platform/dependency-track-admin username=admin password="$password" >/dev/null
  ok "Contraseña de admin guardada en Vault: secret/platform/dependency-track-admin"
fi

jwt="$(curl -fsS -X POST "${DT}/api/v1/user/login" \
  --data-urlencode username=admin --data-urlencode "password=${password}")"
auth=(-H "Authorization: Bearer ${jwt}")

team="$(curl -fsS "${auth[@]}" "${DT}/api/v1/team" | jq -r '.[] | select(.name == "Automation") | .uuid')"
[[ -n "$team" ]] || die "No existe el team Automation"

for perm in BOM_UPLOAD PROJECT_CREATION_UPLOAD VIEW_PORTFOLIO VIEW_VULNERABILITY; do
  curl -s -o /dev/null "${auth[@]}" -X POST "${DT}/api/v1/permission/${perm}/team/${team}" || true
done

if ! vault kv get secret/ci/dependency-track >/dev/null 2>&1 || [[ "${ROTATE:-false}" == "true" ]]; then
  key="$(curl -fsS "${auth[@]}" -X PUT "${DT}/api/v1/team/${team}/key" | jq -er '.key')"
  vault kv put secret/ci/dependency-track api_key="$key" url="$DT" >/dev/null
  ok "API key guardada en Vault: secret/ci/dependency-track"
fi

ok "Dependency-Track listo → http://localhost:8085 (activa DTRACK_ENABLED=true en las variables del repo)"
