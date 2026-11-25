#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Alta de un microservicio en la plataforma (modo local; en GitHub lo hace el
# workflow "Nuevo microservicio"):
#   - Vault: secret/apps/<servicio>/<dev|cert|prod> según secrets: de la configuración
#     de ejemplo de la plantilla (templates/service-<stack>/qt-config/<ambiente>.yaml)
#   - SonarQube: proyecto <servicio> (rama principal master)
#   service-register.sh <servicio> <quarkus|angular>
# -----------------------------------------------------------------------------
source /scripts/lib.sh

service="${1:?servicio}"
stack="${2:?stack}"
config_dir="/templates/service-${stack}/qt-config"
[[ -d "$config_dir" ]] || die "Stack desconocido: ${stack}"

wait_vault_active
vault_root_login
bash /ci-scripts/vault-seed-service.sh "$service" "$config_dir"

# SonarQube (si no, se crea solo en el primer análisis)
SONAR="${SONAR_URL:-http://sonarqube:9000}"
password="$(vault kv get -field=password secret/platform/sonarqube-admin 2>/dev/null || true)"
if [[ -n "$password" ]] && curl -fsS -o /dev/null "${SONAR}/api/system/status" 2>/dev/null; then
  auth="admin:${password}"
  exists="$(curl -fsS -u "$auth" "${SONAR}/api/projects/search?projects=${service}" | jq '.components | length')"
  if [[ "$exists" == "0" ]]; then
    curl -fsS -u "$auth" -X POST "${SONAR}/api/projects/create" \
      --data-urlencode "project=${service}" --data-urlencode "name=${service}" \
      --data-urlencode "mainBranch=master" --data-urlencode "visibility=private" >/dev/null
    ok "SonarQube: proyecto ${service} creado"
  else
    ok "SonarQube: proyecto ${service} ya existe"
  fi
else
  warn "SonarQube no disponible: el proyecto se creará en el primer análisis"
fi
