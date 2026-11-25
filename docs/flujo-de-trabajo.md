# Flujo de trabajo

## Repositorios

| Repo | Qué contiene | Quién lo cambia |
|---|---|---|
| `qt-infra` | Workflows reutilizables, chart común, plantillas, aprovisionamiento | Equipo de plataforma (PR + 1 admin) |
| `qt-<servicio>` | Código + `deploy/` (properties, recursos, HPA, secretos por ambiente) + CI/CD "delgado" que llama a `qt-infra` | Equipo del servicio |
| `qt-gitops` | Snapshot de lo que corre en cada ambiente + add-ons de cada clúster | El pipeline (promociones desde `deploy/`) y personas (add-ons, por PR) |

## Ciclo de vida de una historia

Cada historia, bug o tarea recibe un **código correlativo de la organización**: `QT-1`, `QT-2`… (sin saltos, en cualquier repo). Su rama es `qt/<n>`. **Sin historia no hay despliegue**: solo las ramas `qt/<n>` de una historia abierta llegan a DEV, y CERT y producción salen únicamente de `master`.

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
| **In Progress** | Un dev se **asigna** la historia | Crea la rama `qt/<n>` (por nombre, sin vincularla al issue: así el merge no cierra la historia) |
| **Despliegue DEV** | `git push` a `qt/<n>` | Build, tests, Sonar (análisis de rama), seguridad, imagen firmada → DEV |
| **Pruebas DEV** | DEV quedó *Healthy* | Comenta en la historia la versión desplegada |
| **Rechazo DEV** | `/rechazar <motivo>` en la historia | Vuelve a desarrollo; el siguiente push redespliega |
| **Congelamiento (doing)** | PR `qt/<n>` → `master` aprobado y mergeado | Release del **cambio** `vX.Y.Z-rc.N` + release de **reversión** + **issue de pase**; en CERT: **congela → revierte → recongela** |
| **Congelamiento (done)** | Los tres pasos quedaron *Healthy* | El cambio y su reversión están probados en CERT |
| **Pruebas QA** | QA toma el release (arrastrando el pase) | — |
| **Rechazo QA** | `/rechazar <motivo>` en el issue de pase | Marca los releases como rechazados, cierra el pase y recrea `qt/<n>` para corregir |
| **Gestión de pase** | `/agendar AAAA-MM-DD HH:MM` (hora de Lima) | Pide la **aprobación de un admin** (environment `pase-produccion`); aprobado, queda agendado en Vault |
| **Ejecución de pase** | Llega la fecha y hora | El servicio `pase-ticker` del host vigila la agenda cada minuto y despierta al agendador de `qt-infra`, que dispara el pase: despliega la misma imagen en producción. Si la ejecución se corta antes de desplegar (p. ej. una caída de GitHub), se puede volver a `/agendar` |
| **Ratificación producción** | Producción quedó *Healthy* | Espera la validación del usuario |
| **Done** | `/ratificar` | Release final `vX.Y.Z` (latest, con notas y artefactos), cierra las historias. Es el **único** cierre: si un PR o un `Closes #n` la cierra antes, la plataforma la reabre |
| **Rechazo producción → Reversión** | `/revertir <motivo>` (solo admins), también desde Done | Despliega el release de reversión, reabre las historias y recrea `qt/<n>` |

Convenciones (check "PR Lint / Convenciones"):
- Título en Conventional Commits: `feat:` → minor, `fix:` → patch, `feat!:` → major (minor mientras la versión sea `0.x`).
- Rama `qt/<n>` de una historia **abierta** del mismo repo. El PR no cierra la historia: la cierra la ratificación.

## Workflows de cada microservicio

| Workflow | Se ejecuta | Qué hace |
|---|---|---|
| **CI** | Cada PR a `master` | Validación de `deploy/` (dev, cert, prod). En PRs sin historia (Dependabot, GitHub App) también build, tests, Sonar, seguridad e imagen |
| **CICD DEV** | Push a `qt/<n>` (historia abierta) | **Todas las validaciones** (tests, cobertura, Sonar, Gitleaks, Semgrep, Trivy) + imagen firmada → **DEV**. Marca el commit con `deploy/dev` |
| **CICD CERT** | Merge a `master` | **Congelamiento** sin repetir validaciones: build sin tests e imagen firmada → release del cambio y de reversión → CERT congela, revierte y recongela → issue de pase |
| **CICD PROD** | `/agendar`, `/ratificar` en el issue de pase, y la ejecución agendada | Aprobación del admin, despliegue a **producción** a la hora agendada, release final `vX.Y.Z` |
| **CICD CERT REV** | `/rechazar` en el issue de pase | Descarta el release y CERT vuelve a lo que corre en producción |
| **CICD PROD REV** | `/revertir` en el issue de pase (solo admins) | Producción vuelve a la versión anterior con el release de reversión |
| Auto · Gobierno, Auto · Gobierno (evento), Auto · Tablero, PR Lint | Solos | Aprobaciones y auto-merge, carriles del tablero y convenciones |

## Qué hace falta para mergear a `master`

El merge es automático cuando se cumple **todo** esto; la aprobación del admin sola no alcanza:

| Requisito | Check |
|---|---|
| CI en verde | `CI / Gate` |
| Título y rama de una historia abierta | `PR Lint / Convenciones` |
| Aprobación de un admin | `governance/admin-approvals` |
| **El último commit de la rama se desplegó en DEV y quedó Healthy** | `deploy/dev` (lo publica CICD DEV con la GitHub App) |
| Rama al día con `master` | **Automático**: la plataforma actualiza la rama (ver abajo) y ese commit nuevo vuelve a pasar por CI y por DEV |

`deploy/dev` se pierde con cada push nuevo, hasta que CICD DEV lo despliega, y también con `/rechazar` en pruebas DEV. Para volver a habilitarlo, corrige y haz push, o re-ejecuta **CICD DEV** sobre la rama. Los PRs automáticos (Dependabot, GitHub App) no tienen historia y quedan exentos.

**Ramas al día, sin intervención.** Si un PR aprobado queda atrasado porque `master` avanzó, la plataforma hace merge de `master` en la rama (como el botón *Update branch*):
- **En el momento de la aprobación:** lo hace el gobierno.
- **Después:** lo hace el workflow **Auto · Ramas al día** de `qt-infra`, que el servicio `pase-ticker` del host dispara cada 5 minutos (el cron de GitHub queda de respaldo). Revisa **todos los repos** de la organización, incluidos los micros que se creen después.
- **La aprobación se mantiene**, porque actualizar con `master` no es código nuevo. CI vuelve a correr, y en los microservicios **CICD DEV** redespliega en DEV y renueva `deploy/dev`. El auto-merge termina el trabajo.
- **Conflictos:** si hay conflictos con `master`, la rama no se puede actualizar sola. Hay que resolverlos en la rama, con un push que sí pide aprobar de nuevo.

## Congelamiento y releases

Cada merge a `master` congela un release y prueba en CERT que **se puede revertir**:

| Paso en CERT | Despliega |
|---|---|
| Congela | El release del cambio `vX.Y.Z-rc.N` (imagen de `master` + `deploy/` de ese commit) |
| Revierte | El release de reversión `vX.Y.Z-rc.N-reversion`: **lo que hoy corre en producción** según `qt-gitops`, con la configuración de su propio commit. Si aún no hay nada en producción, la reversión **retira** el servicio |
| Recongela | De nuevo el release del cambio, que queda en CERT para las pruebas |

- Ambos releases se publican en GitHub Releases con `despliegue.json` (imagen, digest y commit). El del cambio también lleva binarios, SBOM y `SHA256SUMS` firmados.
- Un congelamiento nuevo **reemplaza** a los pases aún no ejecutados y anula su agenda.
- **Una sola imagen** (mismo `sha256`) va de CERT a producción.
- Antes de desplegar, el pipeline verifica la **firma cosign** y la **procedencia SLSA**: la imagen la construyó `qt-infra` desde la rama de ese run (`qt/<n>` en DEV, `master` en CERT y producción).
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
- La hora es la de `America/Lima` (variable de organización `PASE_TZ`). El pase arranca como mucho **1 minuto** después de la hora: lo despierta el servicio `pase-ticker` del host de la plataforma. El cron de GitHub (cada 5 min) queda solo de respaldo, porque GitHub lo trata como *best effort* y puede atrasarlo horas.
- Reprogramar (`/agendar` otra vez) anula la aprobación anterior y pide una nueva.
- Tras una **reversión**, el cambio sigue en `master`: corrige en `qt/<n>` (o revierte el código) antes del siguiente congelamiento.

## Crear un microservicio

1. **Actions → Nuevo microservicio → Run workflow** (nombre, `backend` o `frontend`, ruta pública), o un issue **🧩 Nuevo microservicio** en `qt-infra` al que se le agrega el label `aprobado`.
2. Un admin aprueba el environment `provisioning`.
3. El workflow:
   - crea el repo con el esqueleto y la carpeta `deploy/`, y lo protege;
   - crea sus secretos por ambiente en Vault;
   - abre el PR de alta en `qt-gitops` y el PR de su configuración en `qt-config` (1 admin cada uno).

## Configuración por ambiente: `deploy/` del micro + repo `qt-config`

**Lo técnico** viaja con la versión, en la carpeta `deploy/` del microservicio:

| Qué | Archivo (en el repo del servicio) | Llega al pod como |
|---|---|---|
| Puerto, probes, ruta pública, métricas, `requiredConfig` | `deploy/values.yaml` | Deployment, Service, Ingress, ServiceMonitor |
| **Plan de recursos**, réplicas, **HPA**, PDB, reparto entre nodos | `deploy/values-{dev,cert,prod}.yaml` | Deployment, HorizontalPodAutoscaler, PodDisruptionBudget |

**La configuración** de todos los micros, backend y frontend, vive en el repo **`qt-config`**. Cada ambiente lee su carpeta desde su rama:

| Ambiente | Rama | Archivo |
|---|---|---|
| dev | `pre-develop` | `dev/<servicio>-dev.yaml` |
| cert | `develop` | `cert/<servicio>-cert.yaml` |
| prod | `master` | `prod/<servicio>-prod.yaml` |

| Sección del archivo | Qué | Llega al pod como |
|---|---|---|
| `env:` | Variables de entorno no secretas | ConfigMap `<servicio>-config` → env |
| `files:` | **Properties** de Quarkus / `config.json` de Angular | ConfigMap `<servicio>-files` montado como archivo |
| `secrets:` | **Nombres** de los secretos (los valores, en Vault) | Vault `secret/apps/<svc>/<env>` → External Secrets → env |

- **Un cambio de configuración** es un PR contra `pre-develop`. Al mergear, **CICD DEV** lo aplica. La plataforma abre los PRs `pre-develop` → `develop` (**CICD CERT**) y `develop` → `master` (**CICD PROD**), cada uno con 1 aprobación de admin. No hace falta una versión nueva del micro.
- **Cada CICD de qt-config:**
  - crea en Vault las claves nuevas con `generate: true`, sin pisar nunca un valor;
  - escribe `qt-gitops/apps/<svc>/<env>/config.yaml`;
  - espera a que Argo CD deje los pods *Healthy*, y si no, hace rollback.
- **Cada despliegue de una versión** (DEV, congelamiento y pase) verifica que `qt-config` del ambiente tenga lo que esa versión declara en `requiredConfig`. Si falta algo, se frena antes de desplegar.
- Detalle completo: [configuracion.md](configuracion.md).

**Prioridad en Quarkus:** variables de entorno (Secret y `env:`) > `files: application.properties` de qt-config > `src/main/resources/application.properties`.

**Secretos por ambiente** (solo admins; los valores nunca pasan por git):

```powershell
.\qt.ps1 secret-list     qt-pedidos prod                 # nombres de las claves
.\qt.ps1 secret-set      qt-pedidos prod DB_PASSWORD     # pide el valor sin mostrarlo
.\qt.ps1 secret-generate qt-pedidos prod APP_API_KEY     # genera o rota un valor aleatorio
```

External Secrets lo sincroniza en ≤ 15 min, y cada clúster solo lee los secretos de su ambiente.

## Dónde corre cada validación

Las validaciones de calidad y seguridad corren **una sola vez, en DEV**. CERT y producción despliegan exactamente el código y la imagen que ya pasaron por ahí.

| Validación | Bloquea si… | CICD DEV | CI (PR de historia) | CI (PR automático) | CICD CERT / PROD |
|---|---|---|---|---|---|
| Build y tests con cobertura (Maven `--strict-checksums` / `npm ci` + `npm audit signatures`) | Falla un test o el checksum o firma de una dependencia | ✅ | — | ✅ | Solo build, sin tests |
| SonarQube | No pasa el Quality Gate del código nuevo | ✅ | — | ✅ | — |
| Gitleaks · Semgrep · Trivy (repo) | Hay secretos, SAST ERROR o CVEs HIGH/CRITICAL con fix | ✅ | — | ✅ | — |
| Imagen + Trivy | La imagen tiene CVEs HIGH/CRITICAL con fix | ✅ | — | ✅ | Solo build, firma y SBOM |
| Despliegue (dev, cert, prod) | `deploy/` no renderiza o produce manifiestos inválidos | ✅ (al desplegar) | ✅ | ✅ | ✅ (al desplegar) |

- **PRs de historia:** el CI no repite nada, porque el check `deploy/dev` garantiza que el **mismo commit** ya pasó CICD DEV con todas las validaciones.
- **PRs automáticos** (Dependabot, GitHub App): no pasan por DEV, así que el CI los valida completos.
- **Dónde quedan los hallazgos:** como **artefactos del run** (SARIF) y en el resumen de cada job. No se publican en la pestaña *Security* de GitHub, que está desactivada en todos los repos.
- **Checks requeridos por las reglas:** **CI / Gate**, **PR Lint / Convenciones**, **governance/admin-approvals** y, en microservicios, **deploy/dev**.

## Cambios en la plataforma

Como los micros llaman a `qt-infra@master`, un cambio mergeado en `qt-infra` (pipeline, chart o políticas) aplica a **todos** desde su siguiente ejecución. El cambio del chart también llega a los clústeres: Argo CD re-renderiza cada servicio. Por eso `qt-infra` tiene su propio CI, que prueba charts, playbooks y plantillas antes del merge.
