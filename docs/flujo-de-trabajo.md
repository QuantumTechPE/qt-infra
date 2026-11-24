# Flujo de trabajo

## Repositorios

| Repo | Qué contiene | Quién lo cambia |
|---|---|---|
| `qt-infra` | Workflows reutilizables, chart común, plantillas, aprovisionamiento | Equipo de plataforma (PR + 1 admin) |
| `qt-<servicio>` | Código + `deploy/` (properties, recursos, HPA, secretos por ambiente) + CI/CD "delgado" que llama a `qt-infra` | Equipo del servicio |
| `qt-gitops` | Snapshot de lo que corre en cada ambiente + add-ons de cada clúster | El pipeline (promociones desde `deploy/`) y personas (add-ons, por PR) |

## Ciclo de vida de una historia

Cada historia, bug o tarea recibe un **código correlativo de la organización**: `QT-1`, `QT-2`… (sin saltos, en cualquier repo). Su rama es `qt/<n>`. **Sin historia no hay despliegue**: solo las ramas `qt/<n>` de una historia abierta llegan a DEV, y QA y producción salen únicamente de `master`.

```
Backlog → Ready → In Progress → Despliegue DEV → Pruebas DEV ──(/rechazar)──► Rechazo DEV
                                       ▲                │ PR qt/<n> → master (1 admin)
                                       └── push ────────┤
                                                        ▼
            Congelamiento (doing) → Congelamiento (done) → Pruebas QA ──(/rechazar)──► Rechazo QA
            congela · revierte · recongela                     │ /agendar AAAA-MM-DD HH:MM
                                                               ▼
            Gestión de pase (aprobación de admin) → Ejecución de pase (automática, a la hora)
                                                               ▼
            Ratificación producción ──(/ratificar)──► Done ──(/revertir)──► Reversión
                       └──────────(/revertir)──► Rechazo producción ──► Reversión
```

| Carril | Qué lo dispara | Qué hace la plataforma |
|---|---|---|
| **Backlog** | Historia creada (formulario) | Código `QT-<n>` en el título y en el tablero, prioridad, puntos y componente |
| **Ready** | El PO valida la Definition of Ready | (manual, arrastrando la tarjeta) |
| **In Progress** | Un dev se **asigna** la historia | Crea la rama `qt/<n>` vinculada a la historia |
| **Despliegue DEV** | `git push` a `qt/<n>` | Build, tests, Sonar (análisis de rama), seguridad, imagen firmada → DEV |
| **Pruebas DEV** | DEV quedó *Healthy* | Comenta en la historia la versión desplegada |
| **Rechazo DEV** | `/rechazar <motivo>` en la historia | Vuelve a desarrollo; el siguiente push redespliega |
| **Congelamiento (doing)** | PR `qt/<n>` → `master` aprobado y mergeado | Release del **cambio** `vX.Y.Z-rc.N` + release de **reversión** + **issue de pase**; en QA: **congela → revierte → recongela** |
| **Congelamiento (done)** | Los tres pasos quedaron *Healthy* | El cambio y su reversión están probados en QA |
| **Pruebas QA** | QA toma el release (arrastrando el pase) | — |
| **Rechazo QA** | `/rechazar <motivo>` en el issue de pase | Marca los releases como rechazados, cierra el pase y recrea `qt/<n>` para corregir |
| **Gestión de pase** | `/agendar AAAA-MM-DD HH:MM` (hora de Lima) | Pide la **aprobación de un admin** (environment `pase-produccion`); aprobado, queda agendado en Vault |
| **Ejecución de pase** | Llega la fecha y hora | El agendador de `qt-infra` (cada 5 min) dispara el pase: despliega la misma imagen en producción |
| **Ratificación producción** | Producción quedó *Healthy* | Espera la validación del usuario |
| **Done** | `/ratificar` | Release final `vX.Y.Z` (latest, con notas y artefactos), cierra las historias |
| **Rechazo producción → Reversión** | `/revertir <motivo>` (solo admins), también desde Done | Despliega el release de reversión, reabre las historias y recrea `qt/<n>` |

Convenciones (check "PR Lint / Convenciones"):
- Título en Conventional Commits: `feat:` → minor, `fix:` → patch, `feat!:` → major (minor mientras la versión sea `0.x`).
- Rama `qt/<n>` de una historia **abierta** del mismo repo. El PR no cierra la historia: la cierra la ratificación.

## Congelamiento y releases

Cada merge a `master` congela un release y prueba en QA que **se puede revertir**:

| Paso en QA | Despliega |
|---|---|
| Congela | El release del cambio `vX.Y.Z-rc.N` (imagen de `master` + `deploy/` de ese commit) |
| Revierte | El release de reversión `vX.Y.Z-rc.N-reversion`: **lo que hoy corre en producción** según `qt-gitops`, con la configuración de su propio commit. Si aún no hay nada en producción, la reversión **retira** el servicio |
| Recongela | De nuevo el release del cambio, que queda en QA para las pruebas |

- Ambos releases se publican en GitHub Releases con `despliegue.json` (imagen, digest y commit). El del cambio también lleva binarios, SBOM y `SHA256SUMS` firmados.
- Un congelamiento nuevo **reemplaza** a los pases aún no ejecutados y anula su agenda.
- **Una sola imagen** (mismo `sha256`) va de QA a producción.
- Antes de desplegar, el pipeline verifica la **firma cosign** y la **procedencia SLSA**: la imagen la construyó `qt-infra` desde la rama de ese run (`qt/<n>` en DEV, `master` en QA y producción).
- En el clúster, **Kyverno** rechaza cualquier imagen no firmada por el pipeline.
- Si Argo CD no queda *Synced + Healthy*, el pipeline **revierte el commit GitOps** y Argo CD vuelve a la versión anterior. Como el rollout usa `maxUnavailable: 0`, la versión fallida nunca recibe tráfico.

## Pase a producción

Todo ocurre en el **issue de pase** (`[PASE] <servicio> vX.Y.Z-rc.N`), con comandos en comentarios:

| Comando | Cuándo | Quién |
|---|---|---|
| `/rechazar <motivo>` | Pruebas QA o Gestión de pase | QA (permiso de escritura) |
| `/agendar AAAA-MM-DD HH:MM` | Congelamiento (done), Pruebas QA o para reprogramar | Líder (escritura); lo **aprueba un admin** en *Review deployments* |
| `/ratificar` | Ratificación producción | Usuario o QA |
| `/revertir <motivo>` | Ejecución, Ratificación o Done | **Solo admins** |

- La agenda vive en Vault (`secret/platform/pases/<servicio>`). Solo la escribe el job que aprueba un admin, y el pase vuelve a validar todo antes de desplegar: aprobación, hora y que el issue siga abierto.
- La hora es la de `America/Lima` (variable de organización `PASE_TZ`). El agendador revisa cada 5 minutos y GitHub puede retrasar los cron unos minutos en horas de alta carga.
- Reprogramar (`/agendar` otra vez) anula la aprobación anterior y pide una nueva.
- Tras una **reversión**, el cambio sigue en `master`: corrige en `qt/<n>` (o revierte el código) antes del siguiente congelamiento.

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
- Viaja con la versión: dev lo recibe con el push a `qt/<n>`, qa con el congelamiento y prod con el pase.
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

Como los micros llaman a `qt-infra@master`, un cambio mergeado en `qt-infra` (pipeline, chart o políticas) aplica a **todos** desde su siguiente ejecución. El cambio del chart también llega a los clústeres: Argo CD re-renderiza cada servicio. Por eso `qt-infra` tiene su propio CI, que prueba charts, playbooks y plantillas antes del merge.
