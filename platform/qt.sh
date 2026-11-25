#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# qt.sh: orquestador de la plataforma QT (Linux/macOS/Git Bash).
# En Windows/PowerShell: .\qt.ps1 <comando>
#
#   up                              Vault (TLS) + SonarQube + runners, configurados
#   github-app <APP_ID> <CLIENT_ID> <ruta.pem>
#                                   Guarda la GitHub App en Vault y reinicia los runners
#   ssh-key                         Llave SSH para administrar los nodos k3s
#   k8s-provision <dev|cert|prod>     Instala/actualiza k3s en los servidores (Ansible)
#   k8s-local <dev|cert|prod>         Alternativa sin servidores: clúster k3s local (k3d)
#   k8s-local-stop <dev|cert|prod>    Apaga un clúster local (libera su RAM)
#   k8s-local-start <dev|cert|prod>   Enciende un clúster local apagado (robusto tras reiniciar Docker)
#   k8s-bootstrap <dev|cert|prod>     Vault ⇄ clúster + Argo CD + GitOps
#   gitops-render                   Regenera el contenido inicial de qt-gitops (.generated/)
#   secret-list <servicio> <env>    Claves (sin valores) de secret/apps/<servicio>/<env>
#   secret-set <servicio> <env> <CLAVE>      Carga un secreto (pide el valor sin mostrarlo)
#   secret-generate <servicio> <env> <CLAVE> Genera/rota un valor aleatorio
#   xray                            Dependency-Track (SBOM / CVEs)
#   status | logs [servicio] | vault-token | down | destroy
# -----------------------------------------------------------------------------
set -euo pipefail
export MSYS_NO_PATHCONV=1 # evita que Git Bash reescriba rutas como /scripts/...
cd "$(dirname "${BASH_SOURCE[0]}")"

info() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
die() { printf '\033[31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

dc() { docker compose "$@"; }
tool() { dc run --rm -T toolbox bash "/scripts/$1" "${@:2}"; }
tool_tty() { dc run --rm toolbox bash "/scripts/$1" "${@:2}"; }

random_hex() { openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

ensure_env() {
  if [[ ! -f .env ]]; then
    cp .env.example .env
    info "Creado platform/.env a partir de .env.example"
  fi
  if ! grep -qE '^SONAR_DB_PASSWORD=.+' .env; then
    if grep -qE '^SONAR_DB_PASSWORD=' .env; then
      sed -i.bak "s/^SONAR_DB_PASSWORD=.*/SONAR_DB_PASSWORD=$(random_hex)/" .env && rm -f .env.bak
    else
      printf '\nSONAR_DB_PASSWORD=%s\n' "$(random_hex)" >>.env
    fi
  fi
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  [[ "${GITHUB_OWNER:-mi-organizacion}" != "mi-organizacion" ]] ||
    die "Edita platform/.env (GITHUB_OWNER, GITHUB_APP_LOGIN, PLATFORM_HOST...) y vuelve a ejecutar"
  mkdir -p .secrets/runner-approle .secrets/tls .generated
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  up)
    ensure_env
    info "Construyendo toolbox"
    dc build --quiet vault-unsealer
    tool pki-init.sh
    info "Levantando Vault y SonarQube"
    dc up -d vault vault-unsealer sonar-db sonarqube
    if [[ -f .secrets/tls/.reissued ]]; then
      dc restart vault >/dev/null && rm -f .secrets/tls/.reissued
    fi
    tool vault-init.sh
    tool sonar-bootstrap.sh
    info "Levantando runners self-hosted"
    dc up -d runner
    ok "Plataforma arriba"
    cat <<EOF
  Vault      https://localhost:8200   (CA: platform/.secrets/tls/ca.crt · token: ./qt.sh vault-token)
  SonarQube  http://localhost:9000    (admin; contraseña en Vault: secret/platform/sonarqube-admin)
  Runners    ./qt.sh logs runner      (esperan la GitHub App: ./qt.sh github-app ...)
EOF
    ;;

  github-app)
    [[ $# -eq 3 ]] || die "uso: qt.sh github-app <APP_ID> <CLIENT_ID> <ruta-private-key.pem>"
    ensure_env
    cp "$3" .secrets/github-app.pem
    tool vault-github-app.sh "$1" "$2"
    dc up -d --force-recreate runner
    ok "Runners reiniciados con la GitHub App"
    ;;

  ssh-key) ensure_env; tool ssh-key.sh ;;
  secret-list) ensure_env; tool service-secret.sh list "$@" ;;
  secret-generate) ensure_env; tool service-secret.sh generate "$@" ;;
  secret-set)
    [[ $# -eq 3 ]] || die "uso: qt.sh secret-set <servicio> <dev|cert|prod> <CLAVE>"
    ensure_env
    read -rs -p "Valor de $3 para $1 ($2): " value
    echo
    # El valor viaja por stdin (no queda en el historial ni en la lista de procesos)
    printf '%s\n' "$value" | dc run --rm -T toolbox bash /scripts/service-secret.sh set "$1" "$2" "$3"
    unset value
    ;;
  k8s-provision) ensure_env; tool_tty k8s-provision.sh "$@" ;;
  k8s-local)
    # Alternativa sin servidores: clúster k3s en esta máquina (k3d, en Docker)
    ensure_env
    env="${1:-}"
    # Ingress (abierto en la LAN) y API de Kubernetes (solo 127.0.0.1)
    case "$env" in
      dev) port=8081 api=6551 ;;
      cert) port=8082 api=6552 ;;
      prod) port=8083 api=6553 ;;
      *) die "uso: qt.sh k8s-local <dev|cert|prod>" ;;
    esac
    command -v k3d >/dev/null || die "Instala k3d v5.9.0 (https://k3d.io) y vuelve a ejecutar"
    name="qt-${env}"
    # Tope de RAM POR NODO (el clúster local tiene 2 nodos: server + agent). Vacío =
    # sin tope. Solo al CREAR: k3d informa ese tope a Kubernetes (capacidad del nodo).
    # Un tope aplicado después o un tope de CPU quedan ocultos para Kubernetes y
    # desestabilizan el clúster. Para cambiarlo: borrar el clúster y crearlo de nuevo.
    mem_var="LOCAL_NODE_MEMORY_${env^^}"
    node_memory="${!mem_var:-}"
    if k3d cluster get "$name" >/dev/null 2>&1; then
      info "El clúster ${name} ya existe (el tope de RAM solo se aplica al crearlo)"
    else
      info "Creando clúster ${name} (Ingress en el puerto ${port}; RAM por nodo: ${node_memory:-sin tope})"
      memory_args=()
      [[ -n "$node_memory" ]] && memory_args=(--servers-memory "$node_memory" --agents-memory "$node_memory")
      k3d cluster create "$name" --network qt-platform --image rancher/k3s:v1.37.2-k3s1 \
        --servers 1 --agents 1 --k3s-arg "--tls-san=k3d-${name}-server-0@server:0" \
        --api-port "127.0.0.1:${api}" -p "${port}:80@loadbalancer" \
        --kubeconfig-switch-context=false --wait --timeout 300s "${memory_args[@]}"
    fi
    k3d kubeconfig get "$name" |
      sed "s|server: https://.*|server: https://k3d-${name}-server-0:6443|" >".secrets/kubeconfig-${env}"
    set_env_default() {
      if grep -qE "^$1=\s*$" .env; then
        sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
      elif ! grep -qE "^$1=" .env; then
        printf '%s=%s\n' "$1" "$2" >>.env
      else
        return 0
      fi
      info "platform/.env: $1=$2"
    }
    set_env_default "INGRESS_DOMAIN_${env^^}" "${env}.${PLATFORM_HOST%%,*}.nip.io"
    set_env_default "INGRESS_PORT_${env^^}" "$port"
    ok "Clúster ${name} listo (kubeconfig: platform/.secrets/kubeconfig-${env}). Siguiente: ./qt.sh k8s-bootstrap ${env}"
    ;;
  k8s-local-stop)
    [[ "${1:-}" =~ ^(dev|cert|prod)$ ]] || die "uso: qt.sh k8s-local-stop <dev|cert|prod>"
    k3d cluster stop "qt-$1"
    ok "Clúster qt-$1 apagado. Para encenderlo: ./qt.sh k8s-local-start $1"
    ;;
  k8s-local-start)
    # Tras reiniciar Docker las IPs de los contenedores cambian: el agente k3s
    # guarda la IP vieja del server (que puede ser ahora la de OTRO clúster:
    # "not authorized") y `k3d cluster start` se cuelga esperando al agente con el
    # serverlb apagado. Se enciende nodo por nodo, se borra ese caché del agente
    # y se reinician agente y serverlb.
    [[ "${1:-}" =~ ^(dev|cert|prod)$ ]] || die "uso: qt.sh k8s-local-start <dev|cert|prod>"
    name="qt-$1"
    # Recién encendido, Kubernetes aún muestra el "Ready" de antes de apagar: se
    # espera a que server y agente vuelvan a anunciarse en SUS logs (sin relojes).
    log_count() { docker logs "k3d-${name}-$1" 2>&1 | grep -c "$2" || true; }
    srv_before="$(log_count server-0 'k3s is up and running')"
    # Si el server ya estaba encendido no vuelve a anunciarse: no se le espera
    if [[ "$(docker inspect -f '{{.State.Running}}' "k3d-${name}-server-0" 2>/dev/null)" == true ]]; then srv_before=-1; fi
    for node in server-0 agent-0 serverlb; do docker start "k3d-${name}-${node}" >/dev/null; done
    docker exec "k3d-${name}-agent-0" rm -f /var/lib/rancher/k3s/agent/etc/k3s-agent-load-balancer.json \
      /var/lib/rancher/k3s/agent/etc/k3s-api-server-agent-load-balancer.json
    agent_before="$(log_count agent-0 'Successfully registered node')"
    docker restart "k3d-${name}-agent-0" "k3d-${name}-serverlb" >/dev/null
    info "Esperando que server y agente de ${name} se registren..."
    up=false
    for _ in $(seq 1 60); do
      if (($(log_count server-0 'k3s is up and running') > srv_before &&
        $(log_count agent-0 'Successfully registered node') > agent_before)); then
        up=true
        break
      fi
      sleep 5
    done
    [[ "$up" == true ]] || die "El clúster ${name} no se registró a tiempo (revisa: docker logs k3d-${name}-agent-0)"
    ok "Clúster ${name} encendido: server y agente registrados"
    ;;
  k8s-bootstrap) ensure_env; tool k8s-bootstrap.sh "$@" ;;
  gitops-render) ensure_env; tool gitops-render.sh ;;

  xray)
    ensure_env
    dc --profile xray up -d dtrack-apiserver dtrack-frontend
    tool dtrack-bootstrap.sh
    ok "Dependency-Track: http://localhost:8085 — activa la variable de org DTRACK_ENABLED=true"
    ;;

  status)
    dc --profile xray ps
    # --ssl-no-revoke: en Windows (Schannel) no se puede consultar revocación de una CA privada
    curl -s --ssl-no-revoke --cacert .secrets/tls/ca.crt https://127.0.0.1:8200/v1/sys/seal-status | sed 's/,/, /g' || true
    echo
    ;;

  logs) dc --profile xray logs -f --tail 100 "$@" ;;

  vault-token)
    [[ -s .secrets/vault-init.json ]] || die "Vault no está inicializado"
    sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' .secrets/vault-init.json
    ;;

  down) dc --profile xray down ;;

  destroy)
    read -r -p "Esto BORRA Vault, SonarQube y Dependency-Track (datos y secretos). Escribe 'destruir': " answer
    [[ "$answer" == "destruir" ]] || die "Cancelado"
    dc --profile xray --profile tools down -v
    rm -rf .secrets .generated
    ok "Plataforma eliminada"
    ;;

  *) sed -n '2,19p' "$0" ;;
esac
