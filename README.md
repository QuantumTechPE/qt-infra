# qt-infra: plataforma CI/CD + GitOps 100 % gratuita

Plataforma corporativa para microservicios: **un repositorio por microservicio**, **tres ambientes (dev · cert · prod) en tres clústeres Kubernetes on-premise (k3s)**, CI/CD en **GitHub Actions** y despliegue **GitOps con Argo CD**. Todo con herramientas gratuitas u open source.

Este repo es la plataforma: workflows reutilizables, chart común, plantillas de microservicio, aprovisionamiento de clústeres y servicios de soporte (Vault, SonarQube, runners).

## Qué reemplaza a qué

| Necesidad corporativa | Herramienta típica (paga) | Aquí (gratis) |
|---|---|---|
| Gestión de historias | Jira | **GitHub Projects** (tablero de la organización) + Issue Forms |
| CI/CD | Jenkins / Azure DevOps | **GitHub Actions** (workflows reutilizables + runners self-hosted efímeros) |
| Despliegue | Spinnaker / Octopus | **Argo CD** (GitOps) en cada clúster |
| Kubernetes on-premise | OpenShift / Rancher | **k3s** aprovisionado con **Ansible** |
| ConfigMaps / Secrets | — | Configuración por ambiente en el repo **`qt-config`** (dev ← `pre-develop`, cert ← `develop`, prod ← `master`) → ConfigMaps vía `qt-gitops` · Secret desde **Vault** vía **External Secrets** |
| Calidad | SonarQube Developer | **SonarQube Community** + plugin de ramas/PRs |
| SAST | Checkmarx | **Semgrep** |
| SCA / artefactos | JFrog Xray | **Trivy** + **Dependency-Track** |
| Secretos | CyberArk / Vault Enterprise | **HashiCorp Vault** (TLS, OIDC de GitHub, auth Kubernetes) |
| Registro de artefactos | Artifactory | **GHCR** (imágenes) + **GitHub Releases** (binarios) |
| Supply chain | Xray + firma propia | SHA-256 en cada etapa, **cosign**, **SLSA**, SBOM y **Kyverno** (solo imágenes firmadas) |
| Gobierno | Bitbucket DC | Rulesets: `master` intocable, aprobación de un admin y auto-merge |
| Observabilidad | Datadog / Dynatrace | **Grafana + Prometheus + Loki + Alloy** en cada clúster (dev, cert, prod), con dashboard y alertas de microservicios |
| Alta de microservicios | Backstage / tickets manuales | Workflow **Nuevo microservicio** (backend o frontend) con aprobación de admins |

## Arquitectura

```mermaid
flowchart LR
  subgraph GH["GitHub (organización Free)"]
    INFRA["qt-infra<br/>workflows · chart · plantillas"]
    SVC["qt-backend · qt-frontend · ...<br/>1 repo por microservicio"]
    GITOPS["qt-gitops<br/>estado deseado por ambiente"]
    GHCR["GHCR<br/>imágenes firmadas"]
    BOARD["GitHub Projects"]
  end
  subgraph PLAT["Plataforma (Docker en PC/servidor)"]
    V["Vault (TLS)"]
    S["SonarQube"]
    R["Runners efímeros"]
  end
  subgraph K["Clústeres k3s on-premise"]
    DEV["dev<br/>Argo CD"]
    CERT["cert<br/>Argo CD"]
    PROD["prod<br/>Argo CD"]
  end
  BOARD -- "historia → rama" --> SVC
  SVC -- "uses: qt-infra/...@master" --> INFRA
  SVC -- "build · scan · firma" --> GHCR
  R -- "promoción: digest" --> GITOPS
  R --- V & S
  GITOPS -- "sync" --> DEV & CERT & PROD
  DEV & CERT & PROD -- "External Secrets" --> V
  GHCR -. "pull (Kyverno verifica firma)" .-> DEV & CERT & PROD
```

**Despliegues:** push a la rama de la historia `qt/<n>` → **dev** (sin historia no hay despliegue). Merge a `master` → **congelamiento** en **cert** (congela, revierte y recongela) con release del cambio y de reversión. **prod** con un pase agendado, aprobado por un admin y ejecutado automáticamente a la hora indicada; luego se ratifica o se revierte. Ver [flujo de trabajo](docs/flujo-de-trabajo.md).

## Estructura

```
.
├── .github/workflows/
│   ├── service-ci.yml · service-cd.yml           ← los usan TODOS los microservicios
│   ├── service-pr-lint / -governance / -project / -pase.yml · gitops-ci.yml
│   ├── _build · _security · _sonar · _image · _promote.yml   (internos)
│   └── ci.yml · infra-checks.yml · ...            CI propio de qt-infra
├── k8s/
│   ├── charts/qt-service/      chart común: Deployment, Service, Ingress, ConfigMap, ExternalSecret, HPA, PDB, NetworkPolicy
│   ├── charts/cluster-config/  por clúster: ClusterSecretStore (Vault) + política de imágenes firmadas (Kyverno)
│   ├── charts/observability/   por clúster: admin de Grafana desde Vault, dashboard y alertas de microservicios
│   └── provisioning/           Ansible: k3s en tus servidores (inventarios dev, cert, prod)
├── templates/
│   ├── service-quarkus/        backend Java 21 + Quarkus: esqueleto + deploy/ técnico + qt-config/ (configuración inicial)
│   ├── service-angular/        frontend Angular: esqueleto + deploy/ técnico + qt-config/ (config.json inicial)
│   ├── _common/                workflows, gobierno e issue forms de cada repo nuevo
│   ├── gitops/                 contenido inicial de qt-gitops
│   └── config/                 contenido inicial de qt-config (configuración por ambiente)
├── platform/                   Vault · SonarQube · runners · Dependency-Track · toolbox (qt.ps1 / qt.sh)
├── scripts/new-service.sh      crea un microservicio completo con un comando
└── docs/
```

## Empezar

> **Operar la plataforma:** los portales (URL, usuario maestro y dónde está cada contraseña) y qué va en cada archivo de un despliegue están en **[documentacion/](documentacion/README.md)**.

> **Servidor definitivo:** el levantamiento total (migración desde el servidor de pruebas o instalación desde cero, con los parámetros que cambian) está en **[docs/levantamiento.md](docs/levantamiento.md)**.

1. **[docs/puesta-en-marcha.md](docs/puesta-en-marcha.md)**: organización, plataforma, clústeres y primer microservicio.
2. **[docs/flujo-de-trabajo.md](docs/flujo-de-trabajo.md)**: el día a día (historia → PR → dev → cert → prod) y cómo cambiar configuración o secretos.
3. **[docs/seguridad.md](docs/seguridad.md)**: secretos, supply chain, políticas del clúster y límites conocidos.
4. **[docs/observabilidad.md](docs/observabilidad.md)**: Grafana, métricas, logs y alertas por ambiente.
5. **[docs/recursos.md](docs/recursos.md)**: CPU y RAM por ambiente, con la ruta exacta para cambiar cada componente y cada microservicio.
6. **[docs/configuracion.md](docs/configuracion.md)**: el repo `qt-config` (variables, archivos y secretos por ambiente; ramas pre-develop, develop y master).

```powershell
cd platform
.\qt.ps1 up                                   # Vault (TLS) + SonarQube + runners
.\qt.ps1 github-app <APP_ID> <CLIENT_ID> app.pem
.\qt.ps1 ssh-key                              # llave para tus servidores
.\qt.ps1 k8s-provision dev                    # k3s en los servidores de dev (igual cert y prod)
```
```bash
bash platform/scripts/github-bootstrap.sh     # organización + qt-infra + qt-gitops + qt-config (Git Bash)
```
```powershell
.\qt.ps1 k8s-bootstrap dev                    # Vault ⇄ clúster + Argo CD + GitOps (igual cert y prod)
```
Microservicios: **Actions → Nuevo microservicio** en `qt-infra` (o, en local, `bash scripts/new-service.sh qt-backend backend`).

## Costos y límites

- **USD 0** con repos públicos en una organización GitHub Free. En repos privados, la protección de ramas, el auto-merge y los environments con aprobación requieren GitHub Team.
- Los jobs que usan Vault, SonarQube o Argo CD corren en los **runners self-hosted**: si la máquina de la plataforma está apagada, esperan en cola (hasta 24 h).
- Vault corre en un solo nodo con auto-unseal local, apto para laboratorio u on-premise pequeño (ver [seguridad](docs/seguridad.md)).
