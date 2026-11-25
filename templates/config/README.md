# Configuración por ambiente de los microservicios

Aquí vive la configuración de **todos** los microservicios, backend y frontend: variables de entorno, archivos de configuración y los **nombres** de sus secretos. El código de cada micro no la trae, así que se cambia sin recompilar y queda estandarizada en un solo lugar.

## Ramas y carpetas

| Ambiente | Lee la rama | Archivo |
|---|---|---|
| **dev** | `pre-develop` | `dev/<servicio>-dev.yaml` |
| **cert** | `develop` | `cert/<servicio>-cert.yaml` |
| **prod** | `master` | `prod/<servicio>-prod.yaml` |

Las tres ramas tienen las tres carpetas, pero **cada ambiente solo lee la suya, desde su rama**. `<servicio>` es siempre el nombre del repo del microservicio (por ejemplo, `cert/qt-pedidos-cert.yaml`). Lo que cada versión necesita encontrar aquí lo declara en `requiredConfig` de su `deploy/values.yaml`.

## Formato del archivo

```yaml
# Variables de entorno → ConfigMap <servicio>-config
env:
  JAVA_MAX_MEM_RATIO: "75"

# Archivos → ConfigMap <servicio>-files
# (backend: /deployments/config/, frontend: /runtime/config.json)
files:
  application.properties: |
    quarkus.log.level=INFO

# Secretos: SOLO los nombres. Los valores viven en Vault, en
# secret/apps/<servicio>/<ambiente>, y External Secrets los inyecta.
secrets:
  - name: DB_PASSWORD
    generate: false     # la carga un admin: .\qt.ps1 secret-set <servicio> <ambiente> DB_PASSWORD
    description: Contraseña de la base de datos
  - name: API_SIGNING_KEY
    generate: true      # la plataforma crea un valor aleatorio, distinto por ambiente
```

**Nunca** pongas un valor secreto en este repo. El CI corre Gitleaks y rechaza los secretos en claro.

## Cómo cambiar la configuración

1. Crea una rama desde `pre-develop` y abre un PR contra **`pre-develop`**. El CI valida:
   - el formato de cada archivo;
   - que el micro exista;
   - que la configuración, sumada a su `deploy/`, renderice manifiestos válidos.
2. Un admin aprueba y se mergea solo. **CICD DEV** aplica `dev/` en el clúster dev.
3. La plataforma abre el PR **`pre-develop` → `develop`**. Al aprobarlo, **CICD CERT** aplica `cert/`.
4. Luego abre el PR **`develop` → `master`**. Al aprobarlo, **CICD PROD** aplica `prod/`.

Los cambios **siempre** suben en ese orden: `develop` solo acepta PRs desde `pre-develop`, y `master` solo desde `develop`.

## Qué hace cada CICD

| Paso | Detalle |
|---|---|
| Vault | Crea las claves declaradas que falten con `generate: true`. **Nunca pisa un valor.** Avisa las que debe cargar un admin |
| GitOps | Escribe `qt-gitops/apps/<servicio>/<ambiente>/config.yaml` |
| Argo CD | Aplica el cambio. Los pods se reinician solos y el pipeline espera a que queden *Healthy*; si no, hace rollback |

Además, cada despliegue de un microservicio (DEV, congelamiento y pase) **verifica** que su archivo exista y tenga lo que esa versión declara en `requiredConfig`. Así una versión nueva no llega a un ambiente sin su configuración.
