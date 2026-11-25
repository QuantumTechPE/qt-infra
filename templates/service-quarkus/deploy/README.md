# deploy/: cómo corre qt-template-quarkus en cada ambiente

Aquí va **solo lo técnico**. La configuración de cada ambiente vive en el repo **qt-config**.

| Dónde | Qué define | Llega al pod como |
|---|---|---|
| `deploy/values.yaml` | Común: puerto, probes, ruta pública, métricas y `requiredConfig` | Deployment, Service, Ingress, ServiceMonitor |
| `deploy/values-dev.yaml` · `values-cert.yaml` · `values-prod.yaml` | **Plan de recursos** (requests/limits), réplicas, **HPA**, PDB | Deployment, HPA, PDB |
| **qt-config** `<ambiente>/qt-template-quarkus-<ambiente>.yaml` → `env:` | Variables de entorno no secretas | ConfigMap `qt-template-quarkus-config` |
| **qt-config** … → `files:` | `application.properties` del ambiente | ConfigMap montado en `/deployments/config/` |
| **qt-config** … → `secrets:` | **Nombres** de los secretos; valores en Vault `secret/apps/qt-template-quarkus/<ambiente>` | Secret (External Secrets) como variables de entorno |

Cada ambiente lee qt-config desde su rama: dev ← `pre-develop`, cert ← `develop`, prod ← `master`.

**Cómo se aplica:**
- En cada **PR**, el CI renderiza los 3 ambientes con su configuración de qt-config y valida los manifiestos.
- Al **desplegar** (DEV en cada push a `qt/<n>`, cert en el congelamiento y prod en el pase), el pipeline:
  1. verifica que qt-config tenga lo que declara `requiredConfig`;
  2. escribe en `qt-gitops/apps/qt-template-quarkus/<ambiente>/` el snapshot técnico (`values.yaml`) y la configuración vigente (`config.yaml`).
- Un **cambio solo de configuración** no necesita una versión nueva: es un PR en qt-config, y su CICD lo aplica en el ambiente.

**Si el código empieza a usar una propiedad, variable o secreto nuevo:**
1. Agrégalo en `requiredConfig` de `deploy/values.yaml`.
2. Créalo en qt-config para cada ambiente **antes** de desplegar ahí. Si falta, el despliegue se frena con un mensaje claro.

**Secretos:** sus valores se cargan en Vault, nunca en git.

```powershell
.\qt.ps1 secret-list qt-template-quarkus prod             # nombres de las claves cargadas
.\qt.ps1 secret-set  qt-template-quarkus prod DB_PASSWORD # pide el valor sin mostrarlo
```
