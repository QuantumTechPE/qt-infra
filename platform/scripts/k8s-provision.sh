#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Aprovisiona (o actualiza) el clúster k3s de un ambiente con Ansible.
#   k8s-provision.sh <dev|qa|prod> [args extra de ansible-playbook, p. ej. --check]
# Resultado: platform/.secrets/kubeconfig-<ambiente>
# -----------------------------------------------------------------------------
source /scripts/lib.sh

env="${1:?uso: k8s-provision.sh <dev|qa|prod>}"
shift
valid_env "$env"

key="${SECRETS_DIR}/ssh/id_ed25519"
[[ -s "$key" ]] || die "Falta la llave SSH. Ejecuta: qt ssh-key"

# ssh exige permisos 600 (en bind mounts de Windows se ven como 777): copia temporal.
tmpkey="$(mktemp)"
trap 'rm -f "$tmpkey"' EXIT
cp "$key" "$tmpkey"
chmod 600 "$tmpkey"
touch "${SECRETS_DIR}/ssh/known_hosts"

export ANSIBLE_CONFIG=/k8s/provisioning/ansible.cfg
export ANSIBLE_PRIVATE_KEY_FILE="$tmpkey"
cd /k8s/provisioning || exit 1

info "Aprovisionando k3s (${env}) según inventories/${env}/hosts.yml"
ansible-playbook -i "inventories/${env}" site.yml "$@"
ok "Clúster ${env} listo → platform/.secrets/kubeconfig-${env}"
echo "Siguiente paso: qt k8s-bootstrap ${env}"
