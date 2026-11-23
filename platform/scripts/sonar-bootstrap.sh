#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Configura SonarQube de forma idempotente:
#   - reemplaza la contraseña por defecto admin/admin (guardada en Vault)
#   - crea los proyectos qt-backend y qt-frontend (rama principal: master)
#   - emite un token de análisis global para CI y lo guarda en Vault
# -----------------------------------------------------------------------------
source /scripts/lib.sh

SONAR="${SONAR_URL:-http://sonarqube:9000}"

info "Esperando SonarQube (el primer arranque tarda 1-3 min)"
for _ in $(seq 1 120); do
  [[ "$(curl -s "${SONAR}/api/system/status" | jq -r '.status' 2>/dev/null)" == "UP" ]] && break
  sleep 5
done
[[ "$(curl -s "${SONAR}/api/system/status" | jq -r '.status')" == "UP" ]] || die "SonarQube no está UP"

wait_vault_active
vault_root_login

password="$(vault kv get -field=password secret/platform/sonarqube-admin 2>/dev/null || true)"

if [[ "$(curl -s -u admin:admin "${SONAR}/api/authentication/validate" | jq -r '.valid')" == "true" ]]; then
  info "Reemplazando la contraseña por defecto de admin"
  password="$(gen_password)"
  curl -fsS -u admin:admin -X POST "${SONAR}/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin \
    --data-urlencode "password=${password}" >/dev/null
  vault kv put secret/platform/sonarqube-admin username=admin password="$password" >/dev/null
  ok "Contraseña de admin guardada en Vault: secret/platform/sonarqube-admin"
fi
[[ -n "$password" ]] || die "No hay contraseña de admin en Vault y admin/admin ya no es válida"
auth="admin:${password}"

for project in "qt-backend|QT Backend" "qt-frontend|QT Frontend"; do
  key="${project%%|*}"
  name="${project#*|}"
  exists="$(curl -fsS -u "$auth" "${SONAR}/api/projects/search?projects=${key}" | jq '.components | length')"
  if [[ "$exists" == "0" ]]; then
    curl -fsS -u "$auth" -X POST "${SONAR}/api/projects/create" \
      --data-urlencode "project=${key}" --data-urlencode "name=${name}" \
      --data-urlencode "mainBranch=master" --data-urlencode "visibility=private" >/dev/null
    ok "Proyecto ${key} creado"
  fi
done

if ! vault kv get secret/ci/sonarqube >/dev/null 2>&1 || [[ "${ROTATE:-false}" == "true" ]]; then
  curl -s -u "$auth" -X POST "${SONAR}/api/user_tokens/revoke" --data-urlencode name=github-actions >/dev/null || true
  token="$(curl -fsS -u "$auth" -X POST "${SONAR}/api/user_tokens/generate" \
    --data-urlencode name=github-actions --data-urlencode type=GLOBAL_ANALYSIS_TOKEN | jq -er '.token')"
  vault kv put secret/ci/sonarqube token="$token" host_url="$SONAR" >/dev/null
  ok "Token de análisis guardado en Vault: secret/ci/sonarqube"
fi

ok "SonarQube listo → http://localhost:9000 (admin / ver Vault secret/platform/sonarqube-admin)"
