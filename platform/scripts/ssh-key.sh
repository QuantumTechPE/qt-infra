#!/usr/bin/env bash
# Genera (una sola vez) la llave SSH con la que Ansible administra los nodos k3s
# y muestra la pública para agregarla en ~/.ssh/authorized_keys de cada servidor.
source /scripts/lib.sh

dir="${SECRETS_DIR}/ssh"
mkdir -p "$dir"
if [[ ! -s "${dir}/id_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "qt-platform-ansible" -f "${dir}/id_ed25519"
  ok "Llave creada en platform/.secrets/ssh/id_ed25519"
fi
touch "${dir}/known_hosts"
echo
echo "Agrega esta llave pública en ~/.ssh/authorized_keys del usuario de cada nodo (con sudo sin contraseña):"
echo
cat "${dir}/id_ed25519.pub"
