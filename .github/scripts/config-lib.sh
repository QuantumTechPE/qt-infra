#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Repo de configuración por ambiente (qt-config). Cada ambiente lee SU carpeta
# desde SU rama:
#
#   ambiente  rama          archivo
#   dev       pre-develop   dev/<servicio>-dev.yaml
#   cert      develop       cert/<servicio>-cert.yaml
#   prod      master        prod/<servicio>-prod.yaml
#
# Los cambios suben en orden con PRs: pre-develop → develop → master.
# Lo cargan los scripts de CI/CD de los servicios y de qt-config.
# -----------------------------------------------------------------------------

# shellcheck disable=SC2034 # la usan los scripts que cargan este archivo
CONFIG_ENVIRONMENTS=(dev cert prod)

# config_branch <ambiente> → rama de qt-config que lee ese ambiente
config_branch() {
  case "$1" in
    dev) echo pre-develop ;;
    cert) echo develop ;;
    prod) echo master ;;
    *) return 1 ;;
  esac
}

# config_env_of_branch <rama> → ambiente que la lee
config_env_of_branch() {
  case "$1" in
    pre-develop) echo dev ;;
    develop) echo cert ;;
    master) echo prod ;;
    *) return 1 ;;
  esac
}

# config_path <servicio> <ambiente> → ruta del archivo dentro de qt-config
config_path() { echo "$2/$1-$2.yaml"; }

# config_fetch <owner/qt-config> <servicio> <ambiente> <salida>
# Descarga el archivo del ambiente desde su rama. 1 si no existe.
config_fetch() {
  local repo="$1" svc="$2" env="$3" out="$4" branch
  branch="$(config_branch "$env")" || return 1
  if ! gh api -H "Accept: application/vnd.github.raw+json" \
    "repos/${repo}/contents/$(config_path "$svc" "$env")?ref=${branch}" >"$out" 2>/dev/null; then
    rm -f "$out"
    return 1
  fi
}
