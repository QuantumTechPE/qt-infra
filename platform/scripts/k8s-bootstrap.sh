#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Bootstrap GitOps de un clúster (idempotente):
#   1. Vault ⇄ clúster: auth Kubernetes "k8s-<ambiente>" para External Secrets,
#      con acceso SOLO a secret/apps/*/<ambiente>.
#   2. Argo CD (Helm) expuesto en argocd.<dominio>, con cuenta "ci" de solo lectura.
#   3. Aplicación raíz → qt-gitops/clusters/<ambiente>/addons (desde aquí todo es GitOps:
#      External Secrets, Kyverno, config de plataforma y los microservicios).
#   4. Token de la cuenta "ci" → Vault (el pipeline espera Synced + Healthy).
#
#   k8s-bootstrap.sh <dev|qa|prod>     (requiere platform/.secrets/kubeconfig-<ambiente>)
# -----------------------------------------------------------------------------
source /scripts/lib.sh

env="${1:?uso: k8s-bootstrap.sh <dev|qa|prod>}"
valid_env "$env"
: "${GITHUB_OWNER:?}"
INFRA_REPO="${INFRA_REPO:-qt-infra}"
GITOPS_REPO="${GITOPS_REPO:-qt-gitops}"
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com/${GITHUB_OWNER}}"
ARGOCD_CHART_VERSION="10.18.2"

export KUBECONFIG="${SECRETS_DIR}/kubeconfig-${env}"
[[ -s "$KUBECONFIG" ]] || die "No existe ${KUBECONFIG}. Ejecuta primero: qt k8s-provision ${env}"
domain="$(ingress_domain "$env")"
argocd_host="argocd.${domain}"
port="$(ingress_port "$env")"

info "Clúster ${env} ($(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'))"
kubectl get nodes -o wide

# ------------------------------------------------------------ 1. Vault ⇄ Kubernetes
info "Configurando auth Kubernetes en Vault (k8s-${env})"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-tokenreview
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
EOF
for _ in $(seq 1 30); do
  reviewer_jwt="$(kubectl -n kube-system get secret vault-auth-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "$reviewer_jwt" ]] && break
  sleep 2
done
[[ -n "$reviewer_jwt" ]] || die "No se generó el token de vault-auth"
cluster_ca="$(kubectl -n kube-system get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d)"
# URL de la API tal como la ve Vault (por defecto, la del kubeconfig)
k8s_host="${K8S_API_FOR_VAULT:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')}"

wait_vault_active
vault_root_login
vault auth list -format=json | jq -e ".\"k8s-${env}/\"" >/dev/null ||
  vault auth enable -path="k8s-${env}" kubernetes >/dev/null
vault write "auth/k8s-${env}/config" \
  kubernetes_host="$k8s_host" kubernetes_ca_cert="$cluster_ca" \
  token_reviewer_jwt="$reviewer_jwt" disable_local_ca_jwt=true >/dev/null
vault policy write "k8s-${env}" - >/dev/null <<EOF
# External Secrets del clúster ${env}: solo secretos de microservicios de ${env}
# y la credencial de Grafana de ${env}
path "secret/data/apps/+/${env}" { capabilities = ["read"] }
path "secret/data/platform/observability/${env}" { capabilities = ["read"] }
EOF
if ! vault kv get "secret/platform/observability/${env}" >/dev/null 2>&1; then
  vault kv put "secret/platform/observability/${env}" admin-user=admin admin-password="$(gen_password)" >/dev/null
  ok "Vault: credencial de Grafana creada (secret/platform/observability/${env})"
fi
# audience=vault: solo acepta tokens de ServiceAccount emitidos para Vault
# (External Secrets los pide así en el ClusterSecretStore).
vault write "auth/k8s-${env}/role/external-secrets" \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  audience=vault \
  token_policies="k8s-${env}" token_ttl=1h >/dev/null
ok "Vault: auth/k8s-${env} → secret/apps/*/${env}"

# ------------------------------------------------------------ 2. Argo CD
info "Instalando Argo CD (chart ${ARGOCD_CHART_VERSION}) en argocd.${domain}"
values="$(mktemp)"
cat >"$values" <<EOF
global:
  domain: ${argocd_host}
configs:
  params:
    server.insecure: true
  cm:
    accounts.ci: apiKey
    timeout.reconciliation: 120s
    admin.enabled: "true"
  rbac:
    policy.default: ""
    policy.csv: |
      p, role:ci-readonly, applications, get, */*, allow
      g, ci, role:ci-readonly
server:
  ingress:
    enabled: true
    ingressClassName: traefik
dex:
  enabled: false
notifications:
  enabled: false
EOF
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace -f "$values" --wait --timeout 10m >/dev/null
rm -f "$values"
ok "Argo CD instalado"

# ------------------------------------------------------------ 3. Aplicación raíz (GitOps)
kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-${env}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_BASE_URL}/${GITOPS_REPO}.git
    targetRevision: main
    path: clusters/${env}/addons
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: -1
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
EOF
ok "Aplicación raíz cluster-${env} → ${GIT_BASE_URL}/${GITOPS_REPO}.git (clusters/${env}/addons)"

# ------------------------------------------------------------ 4. Token "ci" → Vault
info "Generando token de solo lectura de Argo CD para el pipeline"
admin_pass="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
if [[ -z "$admin_pass" ]]; then
  admin_pass="$(vault kv get -field=password "secret/platform/argocd-admin/${env}" 2>/dev/null || true)"
fi
[[ -n "$admin_pass" ]] || die "No se encontró la contraseña de admin de Argo CD"

kubectl -n argocd port-forward svc/argocd-server 18080:80 >/dev/null 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:18080/healthz 2>/dev/null && break; sleep 1; done

session="$(curl -fsS -H 'Content-Type: application/json' http://127.0.0.1:18080/api/v1/session \
  -d "$(jq -n --arg p "$admin_pass" '{username: "admin", password: $p}')" | jq -er '.token')"
ci_token="$(curl -fsS -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer ${session}" \
  "http://127.0.0.1:18080/api/v1/account/ci/token" -d '{"name":"github-actions"}' | jq -er '.token')"

vault kv put "secret/platform/argocd/${env}" url="${ARGOCD_URL_OVERRIDE:-http://${argocd_host}${port}}" token="$ci_token" >/dev/null
vault kv put "secret/platform/argocd-admin/${env}" username=admin password="$admin_pass" >/dev/null
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
ok "Token de Argo CD en Vault (secret/platform/argocd/${env}); admin en secret/platform/argocd-admin/${env}"

echo
ok "Clúster ${env} en GitOps"
echo "  Argo CD:       http://${argocd_host}${port}   (admin / ver Vault secret/platform/argocd-admin/${env})"
echo "  Grafana:       http://grafana.${domain}${port}   (admin / ver Vault secret/platform/observability/${env})"
echo "  Aplicaciones:  http://qt.${domain}${port}"
