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

# Bloque resources de Helm en una línea (requests de CPU y memoria, límite de memoria)
res() { printf '{requests: {cpu: %s, memory: %s}, limits: {memory: %s}}' "$1" "$2" "$3"; }

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

  # Recursos de los componentes de plataforma (docs/recursos.md):
  #   res <request CPU> <request memoria> <límite de memoria>
  # Valores iniciales; luego se ajustan en qt-gitops/clusters/<ambiente>/addons/.
  declare -A R=(
    [PROMETHEUS]="$(res 100m 1Gi 2Gi)"
    [GRAFANA]="$(res 50m 384Mi 768Mi)"
    [GRAFANA_SIDECAR]="$(res 10m 64Mi 256Mi)"
    [ALERTMANAGER]="$(res 10m 64Mi 128Mi)"
    [PROM_OPERATOR]="$(res 20m 64Mi 256Mi)"
    [KSM]="$(res 10m 64Mi 128Mi)"
    [NODE_EXPORTER]="$(res 10m 32Mi 64Mi)"
    [LOKI]="$(res 50m 256Mi 512Mi)"
    [ALLOY]="$(res 20m 128Mi 256Mi)"
    [KYVERNO_ADMISSION]="$(res 50m 128Mi 384Mi)"
    [KYVERNO_CONTROLLER]="$(res 10m 64Mi 128Mi)"
    [ESO]="$(res 10m 64Mi 192Mi)"
  )
  case "$env" in
    qa)
      R[PROMETHEUS]="$(res 200m 1536Mi 3Gi)"
      R[LOKI]="$(res 100m 384Mi 1Gi)"
      ;;
    prod)
      R[PROMETHEUS]="$(res 300m 2Gi 4Gi)"
      R[GRAFANA]="$(res 100m 512Mi 1Gi)"
      R[ALERTMANAGER]="$(res 20m 64Mi 256Mi)"
      R[KSM]="$(res 20m 64Mi 256Mi)"
      R[LOKI]="$(res 200m 512Mi 2Gi)"
      R[ALLOY]="$(res 50m 128Mi 512Mi)"
      R[KYVERNO_ADMISSION]="$(res 100m 128Mi 512Mi)"
      R[KYVERNO_CONTROLLER]="$(res 20m 64Mi 256Mi)"
      ;;
  esac
  res_args=()
  for k in "${!R[@]}"; do res_args+=(-e "s|__R_${k}__|${R[$k]}|g"); done

  cp -r "$out/clusters/__ENV__" "$out/clusters/${env}"
  grep -rl '__' "$out/clusters/${env}" | xargs sed -i \
    -e "s|__ENV__|${env}|g" \
    -e "s|__INGRESS_DOMAIN__|${domain}|g" \
    -e "s|__IMAGE_POLICY_ACTION__|${action}|g" \
    -e "s|__PROM_RETENTION__|${prom_ret}|g" \
    -e "s|__PROM_STORAGE__|${prom_sto}|g" \
    -e "s|__LOKI_RETENTION__|${loki_ret}|g" \
    -e "s|__LOKI_STORAGE__|${loki_sto}|g" \
    "${res_args[@]}"
  unset R
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

if grep -rnE '__(R_[A-Z_]+|ENV|INGRESS_DOMAIN|IMAGE_POLICY_ACTION|PROM_RETENTION|PROM_STORAGE|LOKI_RETENTION|LOKI_STORAGE|GITHUB_OWNER(_LC)?|INFRA_REPO|GITOPS_REPO|GIT_BASE_URL|VAULT_SERVER|VAULT_CA_B64)__' "$out"; then
  die "Quedaron tokens sin reemplazar"
fi
ok "Repo GitOps generado en platform/.generated/${GITOPS_REPO} (Vault: ${vault_server})"
