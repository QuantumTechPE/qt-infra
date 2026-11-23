# Flujo de trabajo

## Repositorios

| Repo | Qué contiene | Quién lo cambia |
|---|---|---|
| `qt-infra` | Workflows reutilizables, chart común, plantillas, aprovisionamiento | Equipo de plataforma (PR + 1 admin) |
| `qt-<servicio>` | Código + `deploy/` (properties, recursos, HPA, secretos por ambiente) + CI/CD "delgado" que llama a `qt-infra` | Equipo del servicio |
| `qt-gitops` | Snapshot de lo que corre en cada ambiente + add-ons de cada clúster | El pipeline (promociones desde `deploy/`) y personas (add-ons, por PR) |

## Ciclo de una historia

| Evento | Automatización | Tablero |
|---|---|---|
| Historia creada (formulario) en el repo del servicio | Se agrega al tablero de la organización con prioridad, puntos y componente | **Backlog** |
| El PO valida la Definition of Ready | (manual) | **Ready** |
| Un dev se **asigna** la historia | Se crea `feature/<n>-<slug>` vinculada al issue | **In Progress** |
| PR abierto con `Closes #<n>` | CI completo | **In Review** |
| Un admin aprueba y el CI está en verde | **Auto-merge (squash)** | **Done** |

Convenciones (check "PR Lint / Convenciones"):
- Título en Conventional Commits: `feat:` → minor, `fix:` → patch, `feat!:` → major.
- Rama `<tipo>/<n°>-<slug>`.
- `Closes #<n°>` en la descripción.

## Del merge a producción

```
merge a main ─► CD: build · tests · Sonar · Semgrep · Trivy · imagen firmada (GHCR)
              └► dev   (commit en qt-gitops/apps/<svc>/dev → Argo CD → espera Healthy)
release-please abre "chore(release): vX.Y.Z"; al mergearlo (1 admin):
              └► qa    (mismo digest)
              └► prod  (mismo digest, tras aprobación del team admins en el environment "prod")
```

- **Una sola imagen** (mismo `sha256`) recorre los tres ambientes.
- Antes de promover, el pipeline verifica la **firma cosign** y la **procedencia SLSA**: la imagen la construyó `qt-infra` desde `main` de ese repo.
- En el clúster, **Kyverno** rechaza cualquier imagen no firmada por el pipeline.
- Si Argo CD no queda *Synced + Healthy*, el pipeline **revierte el commit GitOps** y Argo CD vuelve a la versión anterior. Como el rollout usa `maxUnavailable: 0`, la versión fallida nunca recibe tráfico.

## Crear un microservicio

1. **Actions → Nuevo microservicio → Run workflow** (nombre, `backend` o `frontend`, ruta pública), o un issue **🧩 Nuevo microservicio** en `qt-infra` al que se le agrega el label `aprobado`.
2. Un admin aprueba el environment `provisioning`.
3. El workflow crea el repo con el esqueleto y la carpeta `deploy/`, lo protege, crea sus secretos por ambiente en Vault y abre el PR de alta en `qt-gitops` (1 admin).

## Configuración por ambiente: carpeta `deploy/` del microservicio

| Qué | Archivo (en el repo del servicio) | Llega al pod como |
|---|---|---|
| Puerto, probes, ruta pública, métricas | `deploy/values.yaml` | Deployment, Service, Ingress, ServiceMonitor |
| **Plan de recursos**, réplicas, **HPA**, PDB, reparto entre nodos | `deploy/values-{dev,qa,prod}.yaml` | Deployment, HorizontalPodAutoscaler, PodDisruptionBudget |
| Variables de entorno no secretas | `config:` en los mismos archivos | ConfigMap → env |
| **Properties** de Quarkus / `config.json` de Angular | `deploy/config/{dev,qa,prod}/` | ConfigMap montado como archivo |
| **Secretos** (solo nombres) | `deploy/vault/secrets.yaml` | Vault `secret/apps/<svc>/<env>` → External Secrets → env |

- Un cambio en `deploy/` pasa por PR (el CI renderiza y valida dev, qa y prod, y publica el plan de recursos en el resumen).
- Viaja con la versión: dev lo recibe en el merge, y qa y prod con el release.
- El pipeline compone `qt-gitops/apps/<svc>/<env>/values.yaml`; no se edita a mano.

**Prioridad en Quarkus:** variables de entorno (Secret y `config:`) > `deploy/config/<env>/application.properties` > `src/main/resources/application.properties`.

**Secretos por ambiente** (solo admins; los valores nunca pasan por git):

```powershell
.\qt.ps1 secret-list     qt-pedidos prod                 # nombres de las claves
.\qt.ps1 secret-set      qt-pedidos prod DB_PASSWORD     # pide el valor sin mostrarlo
.\qt.ps1 secret-generate qt-pedidos prod APP_API_KEY     # genera o rota un valor aleatorio
```

External Secrets lo sincroniza en ≤ 15 min, y cada clúster solo lee los secretos de su ambiente.

## Qué valida cada PR

| Check | Bloquea si... |
|---|---|
| Build y tests (Maven `--strict-checksums` / `npm ci` + `npm audit signatures`) | Falla un test o el checksum o firma de una dependencia |
| SonarQube | No pasa el Quality Gate del código nuevo |
| Gitleaks · Semgrep · CodeQL · Trivy | Hay secretos, SAST ERROR o HIGH, o CVEs HIGH/CRITICAL con fix |
| Dependency Review | Entra una dependencia vulnerable o con licencia AGPL/SSPL |
| Imagen + Trivy | La imagen tiene CVEs HIGH/CRITICAL con fix |
| Despliegue (dev, qa, prod) | `deploy/` no renderiza o produce manifiestos inválidos (recursos, HPA, ConfigMaps) |
| **CI / Gate** · **PR Lint / Convenciones** · **governance/admin-approvals** | Checks requeridos por el ruleset |

## Cambios en la plataforma

Como los micros llaman a `qt-infra@main`, un cambio mergeado en `qt-infra` (pipeline, chart o políticas) aplica a **todos** desde su siguiente ejecución. El cambio del chart también llega a los clústeres: Argo CD re-renderiza cada servicio. Por eso `qt-infra` tiene su propio CI, que prueba charts, playbooks y plantillas antes del merge.
