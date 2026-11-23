#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Instala herramientas en el runner con versión fija y VERIFICANDO su SHA-256
# contra el archivo de checksums publicado por cada proyecto.
#   install-tools.sh helm kubeconform actionlint
# -----------------------------------------------------------------------------
set -euo pipefail

HELM_VERSION="v4.3.2"
KUBECONFORM_VERSION="v0.8.0"
ACTIONLINT_VERSION="1.7.12"

dest="${TOOLS_DIR:-$HOME/.local/bin}"
mkdir -p "$dest"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

fetch() { curl -fsSLO --retry 3 "$1"; }

for tool in "$@"; do
  case "$tool" in
    helm)
      f="helm-${HELM_VERSION}-linux-amd64.tar.gz"
      fetch "https://get.helm.sh/${f}"
      fetch "https://get.helm.sh/${f}.sha256sum"
      sha256sum -c "${f}.sha256sum"
      tar -xzf "$f" linux-amd64/helm
      install -m 0755 linux-amd64/helm "$dest/helm"
      ;;
    kubeconform)
      f="kubeconform-linux-amd64.tar.gz"
      base="https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}"
      fetch "${base}/${f}"
      fetch "${base}/CHECKSUMS"
      grep " ${f}\$" CHECKSUMS | sha256sum -c -
      tar -xzf "$f" kubeconform
      install -m 0755 kubeconform "$dest/kubeconform"
      ;;
    actionlint)
      f="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
      base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}"
      fetch "${base}/${f}"
      fetch "${base}/actionlint_${ACTIONLINT_VERSION}_checksums.txt"
      grep " ${f}\$" "actionlint_${ACTIONLINT_VERSION}_checksums.txt" | sha256sum -c -
      tar -xzf "$f" actionlint
      install -m 0755 actionlint "$dest/actionlint"
      ;;
    *)
      echo "Herramienta desconocida: $tool" >&2
      exit 1
      ;;
  esac
  echo "✔ $tool instalado en $dest"
done

[[ -n "${GITHUB_PATH:-}" ]] && echo "$dest" >>"$GITHUB_PATH"
exit 0
