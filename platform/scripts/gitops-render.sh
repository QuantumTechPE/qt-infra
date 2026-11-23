#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Genera el contenido inicial del repo GitOps (platform/.generated/<GITOPS_REPO>)
# a partir de templates/gitops: una carpeta clusters/<ambiente> por ambiente con
# la URL y CA de Vault, el dominio del Ingress y la identidad del firmante.
# -----------------------------------------------------------------------------
source /scripts/lib.sh

: "${GITHUB_OWNER:?}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
GITOPS_REPO="${GITOPS_REPO:-qt-gitops}"
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com/${GITHUB_OWNER}}"
[[ -s "${TLS_DIR}/ca.b64" ]] || die "No existe la CA interna. Ejecuta: qt up"

out="/generated/${GITOPS_REPO}"
rm -rf "$out"
mkdir -p "$out"
cp -r /templates/gitops/. "$out/"

vault_server="https://$(platform_host):8200"
owner_lc="${GITHUB_OWNER,,}"
ca_b64="$(cat "${TLS_DIR}/ca.b64")"

for env in "${ENVIRONMENTS[@]}"; do
  domain="$(ingress_domain "$env")"
  action_var="IMAGE_POLICY_ACTION_${env^^}"
  action="${!action_var:-Deny}"
  # Observabilidad: retención y almacenamiento crecen con el ambiente
  case "$env" in
    dev) prom_ret=3d; prom_sto=10Gi; loki_ret=72h; loki_sto=10Gi ;;
    qa) prom_ret=7d; prom_sto=20Gi; loki_ret=168h; loki_sto=20Gi ;;
    prod) prom_ret=15d; prom_sto=50Gi; loki_ret=360h; loki_sto=50Gi ;;
  esac
  cp -r "$out/clusters/__ENV__" "$out/clusters/${env}"
  grep -rl '__' "$out/clusters/${env}" | xargs sed -i \
    -e "s|__ENV__|${env}|g" \
    -e "s|__INGRESS_DOMAIN__|${domain}|g" \
    -e "s|__IMAGE_POLICY_ACTION__|${action}|g" \
    -e "s|__PROM_RETENTION__|${prom_ret}|g" \
    -e "s|__PROM_STORAGE__|${prom_sto}|g" \
    -e "s|__LOKI_RETENTION__|${loki_ret}|g" \
    -e "s|__LOKI_STORAGE__|${loki_sto}|g"
  ok "clusters/${env}: Ingress *.${domain} · imágenes ${action} · métricas ${prom_ret} · logs ${loki_ret}"
done
rm -rf "$out/clusters/__ENV__"

grep -rl '__' "$out" | xargs sed -i \
  -e "s|__GITHUB_OWNER_LC__|${owner_lc}|g" \
  -e "s|__GITHUB_OWNER__|${GITHUB_OWNER}|g" \
  -e "s|__INFRA_REPO__|${INFRA_REPO}|g" \
  -e "s|__GITOPS_REPO__|${GITOPS_REPO}|g" \
  -e "s|__GIT_BASE_URL__|${GIT_BASE_URL}|g" \
  -e "s|__VAULT_SERVER__|${vault_server}|g" \
  -e "s|__VAULT_CA_B64__|${ca_b64}|g"

if grep -rnE '__(ENV|INGRESS_DOMAIN|IMAGE_POLICY_ACTION|PROM_RETENTION|PROM_STORAGE|LOKI_RETENTION|LOKI_STORAGE|GITHUB_OWNER(_LC)?|INFRA_REPO|GITOPS_REPO|GIT_BASE_URL|VAULT_SERVER|VAULT_CA_B64)__' "$out"; then
  die "Quedaron tokens sin reemplazar"
fi
ok "Repo GitOps generado en platform/.generated/${GITOPS_REPO} (Vault: ${vault_server})"
