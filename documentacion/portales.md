# Portales de la plataforma

Todos los portales con interfaz web: URL, usuario maestro, dónde está su contraseña y cómo se genera.

> **Regla:** ninguna contraseña se escribe en git, en un chat o en un documento. Todas viven en **Vault** (salvo las dos llaves maestras de Vault, que viven en disco: ver [Vault](#vault)). Los scripts de la plataforma las **generan al azar** la primera vez y las guardan ahí; no hay contraseñas por defecto en uso.

## Resumen

| Portal | URL (instalación local actual) | Usuario maestro | Contraseña |
|---|---|---|---|
| [Vault](#vault) | https://localhost:8200/ui | *(token)* | Root token: `.\qt.ps1 vault-token` |
| [SonarQube](#sonarqube) | http://localhost:9000 | `admin` | Vault `secret/platform/sonarqube-admin` |
| [Dependency-Track](#dependency-track-opcional) *(opcional, apagado)* | http://localhost:8085 | `admin` | Vault `secret/platform/dependency-track-admin` |
| [Argo CD](#argo-cd-uno-por-ambiente) dev | http://argocd.dev.192.168.18.47.nip.io:8081 | `admin` | Vault `secret/platform/argocd-admin/dev` |
| [Argo CD](#argo-cd-uno-por-ambiente) cert | http://argocd.cert.192.168.18.47.nip.io:8082 | `admin` | Vault `secret/platform/argocd-admin/cert` |
| [Argo CD](#argo-cd-uno-por-ambiente) prod | http://argocd.prod.192.168.18.47.nip.io:8083 | `admin` | Vault `secret/platform/argocd-admin/prod` |
| [Grafana](#grafana-uno-por-ambiente) dev | http://grafana.dev.192.168.18.47.nip.io:8081 | `admin` | Vault `secret/platform/observability/dev` |
| [Grafana](#grafana-uno-por-ambiente) cert | http://grafana.cert.192.168.18.47.nip.io:8082 | `admin` | Vault `secret/platform/observability/cert` |
| [Grafana](#grafana-uno-por-ambiente) prod | http://grafana.prod.192.168.18.47.nip.io:8083 | `admin` | Vault `secret/platform/observability/prod` |
| [Aplicaciones](#aplicaciones-microservicios) | http://qt.&lt;ambiente&gt;.192.168.18.47.nip.io:&lt;puerto&gt; | *(las de cada app)* | — |
| [GitHub](#github) | https://github.com/QuantumTechPE | Owner de la organización | Cuenta personal de GitHub (con 2FA) |

**Puertos de los clústeres locales:** dev `8081`, cert `8082`, prod `8083`. Un clúster apagado no responde: `.\qt.ps1 k8s-local-start <ambiente>`. Por memoria, conviene tener encendidos solo dos a la vez.

**En los servidores definitivos** las URL cambian a `http://argocd.<dominio>`, `http://grafana.<dominio>` y `http://qt.<dominio>`, sin puerto (80). El dominio de cada ambiente sale de `ingress_domain` en `k8s/provisioning/inventories/<ambiente>/hosts.yml`, o `<IP del primer nodo>.nip.io` si no se define.

---

## Vault

Guarda **todos** los secretos: los de la plataforma (contraseñas de los portales, la GitHub App, tokens de CI) y los de cada microservicio por ambiente.

| | |
|---|---|
| URL | https://localhost:8200/ui (desde otra máquina de la red: `https://<IP de este PC>:8200/ui`) |
| Ingreso | Método **Token** → pegar el *root token* |
| Root token | `.\qt.ps1 vault-token` (lo imprime en la consola; no lo guardes en otro lado) |
| Certificado | TLS con una CA propia (`platform/.secrets/tls/ca.crt`). El navegador avisa que no es de confianza; para quitar el aviso, importa esa CA como *raíz de confianza*. |

**Cómo se genera:** `.\qt.ps1 up` ejecuta `vault-init.sh`, que hace `vault operator init` (1 llave de desellado, uso local). Vault genera el **root token** y la **unseal key** y ambos quedan en `platform/.secrets/vault-init.json` (fuera de git). El contenedor `qt-vault-unsealer` usa esa llave para desellar Vault cada vez que reinicia.

> Ese archivo es la llave maestra de toda la plataforma: respáldalo cifrado fuera del PC. Si se pierde, los secretos de Vault no se pueden recuperar.

**Dónde está cada cosa en Vault** (menú *Secrets* → `secret/`):

| Ruta | Contenido | Lo crea |
|---|---|---|
| `secret/platform/sonarqube-admin` | `username`, `password` del admin de SonarQube | `sonar-bootstrap.sh` (`qt up`) |
| `secret/platform/dependency-track-admin` | `username`, `password` del admin de Dependency-Track | `dtrack-bootstrap.sh` (`qt xray`) |
| `secret/platform/argocd-admin/<ambiente>` | `username`, `password` del admin de Argo CD | `k8s-bootstrap.sh <ambiente>` |
| `secret/platform/observability/<ambiente>` | `admin-user`, `admin-password` de Grafana | `k8s-bootstrap.sh <ambiente>` |
| `secret/platform/argocd/<ambiente>` | `url`, `token` de la cuenta `ci` de Argo CD (solo lectura, la usan los pipelines) | `k8s-bootstrap.sh <ambiente>` |
| `secret/platform/github-app` | ID, client ID y llave privada de la GitHub App `quantumtechpe-platform` | `.\qt.ps1 github-app ...` |
| `secret/platform/pases`, `secret/platform/story-seq` | Agenda de pases a prod y secuencia de historias (uso interno) | Workflows de pases e historias |
| `secret/ci/sonarqube` | Token de análisis de SonarQube para los pipelines | `sonar-bootstrap.sh` |
| `secret/ci/dependency-track` | API key de Dependency-Track para los pipelines | `dtrack-bootstrap.sh` |
| `secret/apps/<servicio>/<ambiente>` | Secretos de cada microservicio (los nombres se declaran en qt-config) | qt-config (`generate: true`) o `.\qt.ps1 secret-set` |

**Quién más entra a Vault (sin usuario humano):**

| Método | Para quién |
|---|---|
| `jwt-github` (OIDC de GitHub Actions) | Los pipelines: cada workflow obtiene un token de corta duración, limitado a su repo, rama y ambiente |
| `k8s-dev`, `k8s-cert`, `k8s-prod` | External Secrets de cada clúster: lee `secret/apps/*/<su ambiente>` |
| `approle` | El contenedor `qt-pase-ticker` (dispara los pases agendados) |

**Secretos de microservicios desde la consola** (no muestran ni dejan valores en el historial):

```powershell
.\qt.ps1 secret-list     qt-auth-service prod              # nombres de las claves cargadas
.\qt.ps1 secret-set      qt-auth-service prod DB_PASSWORD  # pide el valor sin mostrarlo
.\qt.ps1 secret-generate qt-auth-service prod JWT_KEY      # genera/rota un valor aleatorio
```

---

## SonarQube

Calidad de código (cobertura, bugs, *code smells*) con análisis de ramas y PRs. Cada PR pasa su *Quality Gate*.

| | |
|---|---|
| URL | http://localhost:9000 (solo desde este PC) |
| Usuario | `admin` |
| Contraseña | Vault `secret/platform/sonarqube-admin` → `password` |

**Cómo se genera:** SonarQube arranca con `admin/admin`. `sonar-bootstrap.sh` (lo corre `.\qt.ps1 up`) detecta esa contraseña por defecto, la reemplaza por una aleatoria de 28 caracteres y la guarda en Vault. Si `admin/admin` ya no funciona, lee la de Vault. También crea el token de análisis de los pipelines (`secret/ci/sonarqube`).

La base de datos de SonarQube (PostgreSQL `qt-sonar-db`, usuario `sonar`) usa `SONAR_DB_PASSWORD` de `platform/.env`, un valor hexadecimal aleatorio que genera `qt up` la primera vez. Nadie necesita entrar a esa base.

---

## Dependency-Track (opcional)

Inventario de dependencias (SBOM) de cada versión y sus vulnerabilidades conocidas (CVE). **Hoy está apagado**; Trivy ya escanea cada imagen en el pipeline.

| | |
|---|---|
| Encender | `.\qt.ps1 xray`, y luego la variable de la organización `DTRACK_ENABLED=true` |
| URL | http://localhost:8085 (interfaz) · http://localhost:8086 (API) |
| Usuario | `admin` |
| Contraseña | Vault `secret/platform/dependency-track-admin` → `password` |

**Cómo se genera:** igual que SonarQube. `dtrack-bootstrap.sh` cambia la contraseña por defecto `admin/admin` por una aleatoria, la guarda en Vault y crea la API key de los pipelines (`secret/ci/dependency-track`).

---

## Argo CD (uno por ambiente)

Despliegue GitOps: muestra qué versión de cada micro corre en el clúster, su salud (*Healthy*/*Degraded*) y la sincroniza con el repo `qt-gitops`.

| | |
|---|---|
| URL | `http://argocd.<ambiente>.192.168.18.47.nip.io:<puerto>` |
| Usuario | `admin` |
| Contraseña | Vault `secret/platform/argocd-admin/<ambiente>` → `password` (distinta en cada ambiente) |

**Cómo se genera:** al instalarse, Argo CD crea una contraseña aleatoria para `admin` en el Secret `argocd-initial-admin-secret`. `k8s-bootstrap.sh <ambiente>` la copia a Vault y **borra ese Secret** del clúster, así la única copia queda en Vault.

**Cuenta `ci`:** la crea el mismo bootstrap, sin contraseña (solo token de API) y con permiso de **solo lectura** de aplicaciones y logs. La usan los pipelines para esperar a que un despliegue quede *Healthy* y, si falla, mostrar el diagnóstico al dev. Su token está en `secret/platform/argocd/<ambiente>`.

> No cambies nada a mano desde Argo CD (*Sync*, *Edit*): el estado deseado es el de `qt-gitops`, y Argo CD revierte los cambios manuales (*self-heal*).

---

## Grafana (uno por ambiente)

Observabilidad del ambiente: métricas (Prometheus), logs (Loki), trazas (Tempo) y alertas. Trae el dashboard *QT · Microservicios*.

| | |
|---|---|
| URL | `http://grafana.<ambiente>.192.168.18.47.nip.io:<puerto>` |
| Usuario | `admin` (Vault → `admin-user`) |
| Contraseña | Vault `secret/platform/observability/<ambiente>` → `admin-password` (distinta en cada ambiente) |

**Cómo se genera:** `k8s-bootstrap.sh <ambiente>` crea en Vault una contraseña aleatoria de 28 caracteres, solo si no existe. External Secrets la lleva al Secret `grafana-admin` del clúster y Grafana la toma de ahí.

**Prometheus, Alertmanager, Loki y Tempo** no tienen portal propio: se consultan desde Grafana (*Explore* y *Alerting*). Ver [observabilidad.md](../docs/observabilidad.md).

---

## Aplicaciones (microservicios)

Todas las aplicaciones de un ambiente comparten un host y se separan por ruta:

| Ambiente | Frontend (qt-portal) | Backend (ej. qt-auth-service) |
|---|---|---|
| dev | http://qt.dev.192.168.18.47.nip.io:8081/ | http://qt.dev.192.168.18.47.nip.io:8081/api/auth/ping |
| cert | http://qt.cert.192.168.18.47.nip.io:8082/ | http://qt.cert.192.168.18.47.nip.io:8082/api/auth/ping |
| prod | http://qt.prod.192.168.18.47.nip.io:8083/ | http://qt.prod.192.168.18.47.nip.io:8083/api/auth/ping |

El frontend se publica en `/` y cada backend en su prefijo `/api/...`. Health (`/q/health`, `/healthz`) y métricas (`/q/metrics`) **no** se publican: solo los usan Kubernetes y Prometheus dentro del clúster. Los usuarios de cada aplicación son responsabilidad de la aplicación (no de la plataforma).

---

## GitHub

| Portal | URL | Para qué |
|---|---|---|
| Organización | https://github.com/QuantumTechPE | Repos de la plataforma y de cada microservicio |
| Tablero *QT Delivery* | https://github.com/orgs/QuantumTechPE/projects/1 | Historias y su avance por carril (Backlog → DEV → Congelamiento → Pase → Done) |
| Actions | `https://github.com/QuantumTechPE/<repo>/actions` | Pipelines (CICD DEV, CERT, PROD) y sus aprobaciones |
| Paquetes (GHCR) | https://github.com/orgs/QuantumTechPE/packages | Imágenes firmadas de cada microservicio |

**Usuario maestro:** el *owner* de la organización, el único admin. Es una cuenta personal de GitHub con 2FA; sus credenciales no las maneja la plataforma. Es quien **aprueba** PRs, congelamientos y pases a prod (1 aprobación).

**GitHub App `quantumtechpe-platform`:** la "cuenta de servicio" de la plataforma. Abre PRs, mueve el tablero, registra los runners y escribe en `qt-gitops`. No tiene contraseña: usa una llave privada guardada en Vault (`secret/platform/github-app`) y obtiene tokens de 1 hora. Para registrarla o rotar la llave: `.\qt.ps1 github-app <APP_ID> <CLIENT_ID> <ruta.pem>` y luego borra el `.pem` del disco.

---

## Para los servidores definitivos

Lo de arriba es adecuado para una instalación local con un solo admin. Al pasar a servidores definitivos conviene:

| Hoy | Recomendado |
|---|---|
| Vault con *root token* | Revocar el root token y entrar con usuarios propios (método OIDC con GitHub o `userpass`); auto-unseal con KMS o Vault Transit en vez de la llave en disco |
| `admin` compartido en Argo CD, Grafana y SonarQube | Inicio de sesión con GitHub (SSO) y roles por equipo; dejar `admin` solo como cuenta de emergencia |
| HTTP en Argo CD, Grafana y aplicaciones | HTTPS con certificados (cert-manager) en el Ingress |
| `nip.io` | DNS propio del dominio de la empresa |
