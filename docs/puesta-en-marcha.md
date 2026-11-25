# Puesta en marcha

De cero a tres clústeres con microservicios desplegados por GitOps.

## 0. Qué necesitas

| Qué | Para qué |
|---|---|
| **Máquina de plataforma**: tu PC con Docker Desktop o, mejor, un servidor Linux con Docker | Vault, SonarQube, runners self-hosted y toolbox (Ansible, kubectl, Helm). Debe ser alcanzable por los clústeres (puerto 8200) |
| **Servidores/VMs Linux** con systemd para k3s | 3 clústeres: dev, cert y prod (mínimo 1 nodo cada uno; prod recomendado con 3 control-plane) |
| Git + Git Bash y **GitHub CLI** (`winget install GitHub.cli`) | Bootstrap de GitHub y alta de microservicios |
| Node.js ≥ 24.15 y JDK 21 | Solo para desarrollar en local |

**Red entre componentes:**

| Desde | Hacia | Puerto | Para |
|---|---|---|---|
| Nodos de los clústeres | Máquina de plataforma | 8200/tcp | External Secrets → Vault |
| Máquina de plataforma | Control-plane de cada clúster | 6443/tcp | Vault (TokenReview) y toolbox (kubectl/helm) |
| Máquina de plataforma | Nodos de cada clúster | 22/tcp, 80/tcp | Ansible (SSH) y runners → Argo CD (Ingress) |
| Nodos entre sí | — | 6443, 10250/tcp, 8472/udp (+2379-2380 en HA) | k3s |
| Todo | Internet | 443 | GitHub, GHCR, charts, Sigstore |

## 1. Organización en GitHub y GitHub App

1. Crea una organización gratuita: <https://github.com/account/organizations/new?plan=free>.
2. Crea la App con los permisos ya marcados abriendo este enlace (reemplaza `ORG` por tu organización y, si quieres, el nombre):

   ```
   https://github.com/organizations/ORG/settings/apps/new?name=ORG-platform&url=https%3A%2F%2Fgithub.com%2FORG&public=false&webhook_active=false&administration=write&contents=write&issues=write&pull_requests=write&statuses=write&workflows=write&metadata=read&members=read&organization_projects=write&organization_self_hosted_runners=write
   ```

   O manualmente, en **Organization settings → Developer settings → GitHub Apps → New GitHub App**:
   - **Webhook**: desmarca *Active*.
   - **Repository permissions**: Administration, Contents, Issues, Pull requests, Commit statuses y Workflows en **Read & write**; Metadata en Read. Administration y Workflows le permiten crear y configurar los repos de micros nuevos.
   - **Organization permissions**: Projects y Self-hosted runners en **Read & write**; Members en Read.
   - Anota el **App ID** (número) y el **Client ID**, y genera una **private key** (`.pem`).
   - **Install App** → tu organización → **All repositories**, para que cada micro nuevo quede cubierto.

La App es la cuenta de servicio del pipeline: registra runners, publica el check de gobierno, habilita auto-merge, crea las ramas de las historias, escribe las promociones en `qt-gitops` y mueve el tablero. Su clave vive **solo en Vault**.

## 2. Plataforma

```powershell
cd E:\QT\Infra\platform
.\qt.ps1 up          # la primera vez crea platform/.env y se detiene
notepad .env
```

```ini
GITHUB_OWNER=mi-organizacion       # mayúsculas/minúsculas exactas
GITHUB_APP_LOGIN=mi-organizacion
GOVERNANCE_APP_ID=123456
PLATFORM_HOST=192.168.1.50         # IP/DNS de esta máquina vista desde los clústeres
```

```powershell
.\qt.ps1 up
.\qt.ps1 github-app 123456 Iv23liXXXXXXXX C:\ruta\qt-platform-bot.pem
.\qt.ps1 logs runner                # debe decir "Listening for Jobs"
```

`up` es idempotente. En cada ejecución:
- **PKI interna**: crea la CA y el certificado de Vault con los SAN de `PLATFORM_HOST`.
- **Vault en TLS**: KV v2, auditoría, roles OIDC para toda la organización atados a los workflows de `qt-infra`, y AppRole para los runners. El auto-unseal se encarga de los reinicios.
- **SonarQube**: cambia la contraseña de admin y genera el token de análisis, que guarda en Vault.
- **Runners**: arranca los runners efímeros a nivel organización.

Si en Windows el firewall bloquea el puerto 8200, habilítalo para la red de los servidores.

## 3. Clústeres k3s (dev, cert y prod)

```powershell
.\qt.ps1 ssh-key      # muestra la llave pública: agrégala en ~/.ssh/authorized_keys de cada nodo
```

Edita los inventarios con las IPs de tus servidores:
- `k8s/provisioning/inventories/dev/hosts.yml`
- `k8s/provisioning/inventories/cert/hosts.yml`
- `k8s/provisioning/inventories/prod/hosts.yml`

Cada nodo necesita un usuario con sudo sin contraseña. El dominio del Ingress es por defecto `<IP del primer control-plane>.nip.io` (DNS wildcard gratuito). Si tienes DNS propio, define `ingress_domain`.

```powershell
.\qt.ps1 k8s-provision dev
.\qt.ps1 k8s-provision cert
.\qt.ps1 k8s-provision prod
```

Ansible instala **k3s 1.37.2** con el instalador oficial fijado a esa versión, que verifica el SHA-256 del binario. Habilita el cifrado de secretos en etcd, levanta HA con etcd embebido si hay varios control-plane y deja `platform/.secrets/kubeconfig-<ambiente>`. Es idempotente: para actualizar k3s, cambia `k3s_version` en `group_vars/all.yml` y vuelve a ejecutarlo.

### Alternativa: los 3 clústeres en esta PC (k3d)

Mientras no tengas servidores, `k8s-local` crea cada clúster como contenedores Docker. Usa el mismo k3s 1.37.2 y la red de la plataforma, así que Vault y el toolbox lo alcanzan por nombre:

```powershell
.\qt.ps1 k8s-local dev     # Ingress en :8081
.\qt.ps1 k8s-local cert      # Ingress en :8082
.\qt.ps1 k8s-local prod    # Ingress en :8083
```

Descarga k3d 5.9.0 en `platform/.bin` y verifica su SHA-256. Deja `platform/.secrets/kubeconfig-<ambiente>` y completa en `.env` `INGRESS_DOMAIN_<AMBIENTE>=<ambiente>.<PLATFORM_HOST>.nip.io` e `INGRESS_PORT_<AMBIENTE>`. Las URLs quedan como `http://grafana.dev.192.168.18.47.nip.io:8081`. También agrega los contextos `k3d-qt-<ambiente>` a tu `~/.kube/config`.

Para ahorrar RAM, apaga el clúster que no uses y vuelve a encenderlo cuando haga falta:

```powershell
.\qt.ps1 k8s-local-stop prod
.\qt.ps1 k8s-local-start prod   # también tras reiniciar Docker (no uses "k3d cluster start")
```

Para pasar al servidor definitivo, sigue [levantamiento.md](levantamiento.md).

Ten en cuenta:
- Los 3 clústeres con su observabilidad usan unos 9-10 GB de RAM, sumados a SonarQube (~3 GB). Si Docker se queda corto, detén SonarQube mientras no analices (`docker stop qt-sonarqube`).
- Si cambia la IP de la PC, cambia `PLATFORM_HOST` y los `INGRESS_DOMAIN_*`, y vuelve a ejecutar `qt up` y `gitops-render`.
- Al migrar a servidores reales, vacía `INGRESS_DOMAIN_*` e `INGRESS_PORT_*` y sigue los pasos de arriba.

## 4. GitHub: organización, qt-infra, qt-gitops y qt-config

Desde **Git Bash**, en la raíz del repo:

```bash
gh auth login -s admin:org,project,workflow
ADMINS="ana,luis" DEVELOPERS="pedro,maria" bash platform/scripts/github-bootstrap.sh
```

> **Aprobaciones requeridas.** Basta **1 aprobación de un admin** (`ADMIN_APPROVALS_REQUIRED=1` en `platform/.env`). GitHub no deja que el autor apruebe su propio PR, así que hace falta al menos otro admin además del autor. Para exigir más, cambia el valor y vuelve a ejecutar el bootstrap (es idempotente).

| Ámbito | Resultado |
|---|---|
| Organización | Teams `admins` y `developers`. Política de Actions: allowlist, `GITHUB_TOKEN` de solo lectura, forks con aprobación y runners habilitados para repos públicos |
| Tablero | GitHub Project con los 16 carriles del flujo (Backlog → Despliegue DEV → Congelamiento → Gestión de pase → … → Done, ver [flujo-de-trabajo.md](flujo-de-trabajo.md)), más Código, Versión, Pase, Prioridad, Story points y Componente |
| Variables de org | `VAULT_ADDR`, `VAULT_CA_B64`, `VAULT_AUDIENCE`, `GITOPS_REPO`, `CONFIG_REPO`, `PROJECT_NUMBER`... (**ningún secreto**) |
| `qt-infra` | Push inicial y repo protegido |
| `qt-gitops` | Se genera con `clusters/dev`, `clusters/cert` y `clusters/prod` (URL y CA de Vault, dominio del Ingress, política de imágenes) y se protege. La GitHub App puede escribir las promociones |
| `qt-config` | Configuración por ambiente de los micros. Se crea con las ramas `pre-develop` (dev), `develop` (cert) y `master` (prod), sus CICD y sus environments, y se protege (PR + CI + 1 admin). Ver [configuracion.md](configuracion.md) |

Paso manual (la API no lo expone): **Tablero → Workflows** → activa *Item closed* y *Pull request merged* → Done.

## 5. Bootstrap GitOps de cada clúster

```powershell
.\qt.ps1 k8s-bootstrap dev
.\qt.ps1 k8s-bootstrap cert
.\qt.ps1 k8s-bootstrap prod
```

| Paso | Resultado |
|---|---|
| Vault ⇄ clúster | Auth Kubernetes `k8s-<ambiente>`: External Secrets solo puede leer `secret/apps/*/<ambiente>` |
| Argo CD | Instalado en `argocd.<dominio>`, con cuenta `ci` de solo lectura (su token queda en Vault) |
| Aplicación raíz | Apunta a `qt-gitops/clusters/<ambiente>/addons`. Desde ahí, Argo CD instala External Secrets, Kyverno, el ClusterSecretStore, la política de imágenes firmadas, la **observabilidad** (Prometheus, Grafana, Loki y Alloy) y el ApplicationSet de microservicios |
| Grafana | `http://grafana.<dominio>`, con un admin propio del ambiente en Vault (`secret/platform/observability/<ambiente>`). Ver [observabilidad](observabilidad.md) |

La contraseña de admin de Argo CD queda en Vault, en `secret/platform/argocd-admin/<ambiente>`.

## 6. Microservicios

Recomendado: **Actions → Nuevo microservicio → Run workflow** en `qt-infra`, con el nombre, el tipo (`backend` o `frontend`) y la ruta pública. También puedes abrir un issue **🧩 Nuevo microservicio** y agregarle el label `aprobado`. En ambos casos un admin aprueba el environment `provisioning`.

Alternativa local (Git Bash, plataforma arriba):

```bash
bash scripts/new-service.sh qt-backend backend                     # API en /api
bash scripts/new-service.sh qt-pedidos backend --api-path /api/pedidos
bash scripts/new-service.sh qt-frontend frontend                   # SPA en /
```

Resultado:
1. Repo `<org>/<nombre>` con el esqueleto vacío y su estructura de capas, y la carpeta `deploy/`:
   - properties y ConfigMaps por ambiente;
   - plan de recursos y HPA por ambiente;
   - secretos declarados para Vault.
   
   Los pipelines ya vienen conectados a `qt-infra`.
2. Repo protegido: rulesets, environments `dev`/`cert`/`prod` (prod con aprobación de admins), seguridad y labels.
3. Vault: `secret/apps/<nombre>/{dev,cert,prod}`, con valores aleatorios distintos por ambiente para las claves `generate: true`.
4. Un **PR en `qt-gitops`** con `apps/<nombre>/`. Cuando un admin lo aprueba, Argo CD de cada clúster empieza a gestionarlo.

El primer despliegue a DEV ocurre con el primer push a la rama de una historia (`qt/<n>`, workflow **CICD DEV**); el merge a `master` congela el release en CERT (**CICD CERT**). Ver [flujo-de-trabajo.md](flujo-de-trabajo.md).

## Operación

```powershell
.\qt.ps1 status | logs <servicio> | down | up
```

| Síntoma | Causa y solución |
|---|---|
| Jobs en "Waiting for a runner" | La plataforma está apagada, o la App no está en Vault: `.\qt.ps1 logs runner` |
| `permission denied` de Vault en un job | El repo no llama a `qt-infra@master`, o `GITHUB_OWNER` no coincide en mayúsculas |
| Promoción: "no está dado de alta" | Falta mergear el PR de `apps/<servicio>` en `qt-gitops` |
| Pod rechazado por Kyverno | La imagen no fue firmada por `qt-infra/_image.yml` (solo el CD publica imágenes desplegables) |
| ExternalSecret en error | Revisa `kubectl get clustersecretstore vault` (red o certificado hacia Vault en el puerto 8200) |
