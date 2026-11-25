# Configuración por ambiente (repo `qt-config`)

La configuración de **todos** los microservicios, backend y frontend, vive en un solo repo: **`qt-config`**. Ahí están las variables de entorno, los archivos de configuración y los **nombres** de los secretos. El repo de cada micro trae solo lo técnico (`deploy/`: recursos, HPA, PDB).

## Ramas, carpetas y nombres

| Ambiente | Lee la rama | Archivo | Lo aplica |
|---|---|---|---|
| **dev** | `pre-develop` | `dev/<servicio>-dev.yaml` | **CICD DEV** |
| **cert** | `develop` | `cert/<servicio>-cert.yaml` | **CICD CERT** |
| **prod** | `master` | `prod/<servicio>-prod.yaml` | **CICD PROD** |

- `<servicio>` es el nombre del repo del microservicio, por ejemplo `cert/qt-pedidos-cert.yaml`.
- Las tres ramas tienen las tres carpetas, pero cada ambiente solo lee la suya, desde su rama.
- Los cambios suben **siempre en orden**: `pre-develop` → `develop` → `master`. El CI de qt-config rechaza un PR a `develop` que no venga de `pre-develop`, y uno a `master` que no venga de `develop`.

## Formato

```yaml
env:            # variables de entorno → ConfigMap <servicio>-config
  JAVA_MAX_MEM_RATIO: "75"
  ERP_URL: https://erp.cert.miempresa.local

files:          # archivos → ConfigMap <servicio>-files
  application.properties: |      # backend: montado en /deployments/config/
    quarkus.log.level=INFO
  # config.json: |               # frontend: servido en /runtime/config.json

secrets:        # SOLO nombres; valores en Vault secret/apps/<servicio>/<ambiente>
  - name: DB_PASSWORD
    generate: false              # la carga un admin (.\qt.ps1 secret-set)
  - name: API_SIGNING_KEY
    generate: true               # la plataforma crea un valor aleatorio, distinto por ambiente
```

| Regla | Detalle |
|---|---|
| Nombres de variable | `MAYÚSCULAS`, letras, números y `_` |
| Valores de `env` | Texto o número; listas y mapas no |
| Nombres de archivo | Sin `/`. El contenido va como texto (`|`) |
| Secretos | **Nunca** con valor. El CI corre Gitleaks y rechaza secretos en claro |

## Flujo de un cambio

```
rama de trabajo ──PR──► pre-develop ──CICD DEV──► clúster dev
                            │ (PR automático)
                            ▼
                         develop ─────CICD CERT──► clúster cert
                            │ (PR automático)
                            ▼
                          master ─────CICD PROD──► clúster prod
```

1. Crea una rama desde `pre-develop`, edita el archivo y abre el PR contra `pre-develop`. El CI valida:
   - el formato;
   - que el micro exista;
   - que la configuración, sumada a su `deploy/` actual, renderice manifiestos válidos.
2. Un admin aprueba y el PR se mergea solo.
3. **CICD DEV** aplica `dev/`. **Auto · Promoción** abre o actualiza el PR `pre-develop` → `develop`.
4. Al aprobarlo (merge commit), **CICD CERT** aplica `cert/`, y se abre el PR `develop` → `master`.
5. Al aprobarlo, **CICD PROD** aplica `prod/`.

Cada CICD de qt-config, en este orden:

| Paso | Qué hace |
|---|---|
| Vault | Agrega las claves declaradas que falten con `generate: true`. **Nunca lee ni pisa un valor existente para cambiarlo.** Avisa las `generate: false` que falten |
| GitOps | Escribe `qt-gitops/apps/<servicio>/<ambiente>/config.yaml`. Argo CD lo combina con el `values.yaml` técnico del micro |
| Argo CD | Espera a que los servicios que cambiaron queden *Synced + Healthy*. Si no, **rollback** automático. Los pods se reinician solos porque el Deployment lleva la huella de sus ConfigMaps |

## Configuración y versiones del micro

Un cambio de configuración **no necesita una versión nueva** del micro. Pero si una versión nueva **usa** una variable, archivo o secreto nuevo:

1. El micro lo declara en `deploy/values.yaml`:
   ```yaml
   requiredConfig:
     env: [ERP_URL]
     files: [application.properties]
     secrets: [DB_PASSWORD]
   ```
2. **Antes** de desplegar esa versión en un ambiente, agrega la configuración en qt-config para ese ambiente.
3. Cada despliegue verifica `requiredConfig` contra la rama del ambiente: el push a `qt/<n>` (DEV), el congelamiento (cert) y el pase (prod). Si falta algo, **se frena antes de tocar el clúster**, con el detalle de lo que falta.

Al desplegar, el micro escribe también la configuración **vigente** del ambiente (`config.yaml`) en el mismo commit GitOps. Así nunca queda una versión sin su configuración, aunque qt-config se haya mergeado antes que el alta del micro.

## Microservicios nuevos

El workflow **Nuevo microservicio** abre el PR de configuración inicial contra `pre-develop`, con los tres archivos. Vienen de la plantilla: `templates/service-<stack>/qt-config/`. También siembra en Vault los secretos `generate: true` de cada ambiente. Las promociones a `develop` y `master` se abren solas.

## Seguridad

- Los rulesets protegen las tres ramas: PR, CI en verde y la aprobación de un admin (team `admins`, CODEOWNERS).
- **Vault:** cada CICD se autentica con OIDC en un rol propio, `gha-config-<ambiente>`, que solo acepta:
  - el repo `qt-config`;
  - la **rama** de ese ambiente;
  - su **environment** de GitHub;
  - el workflow `config-cd.yml` de `master` de qt-infra.
  Su policy (`config-<ambiente>`) lee los nombres y agrega claves solo en `secret/apps/*/<ambiente>`.
- Las promociones usan `gha-config-promotion`, que solo puede abrir PRs.
