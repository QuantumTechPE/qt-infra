# deploy/: cómo corre qt-template-quarkus en cada ambiente

| Archivo | Qué define | Llega al pod como |
|---|---|---|
| `values.yaml` | Común: puerto, probes, ruta pública, métricas | Deployment, Service, Ingress, ServiceMonitor |
| `values-dev.yaml` · `values-qa.yaml` · `values-prod.yaml` | **Plan de recursos** (requests/limits), réplicas, **HPA**, PDB, variables de entorno no secretas (`config:`) | Deployment, HPA, PDB, ConfigMap (env) |
| `config/<ambiente>/application.properties` | Propiedades de Quarkus del ambiente | ConfigMap montado en `/deployments/config/` |
| `vault/secrets.yaml` | Nombres de los secretos (`secret/apps/qt-template-quarkus/<ambiente>`) | Secret (External Secrets) como variables de entorno |

**Cómo se aplica:**
- En cada **PR**, el CI renderiza los 3 ambientes y valida los manifiestos.
- Al **promover** (dev en cada merge; qa y prod en cada release), el pipeline compone estos archivos en `qt-gitops/apps/qt-template-quarkus/<ambiente>/values.yaml` junto con el digest de la imagen. Argo CD del clúster aplica el cambio.

Así la configuración viaja con la versión: prod recibe exactamente la configuración del release aprobado.

**Secretos:** se cargan en Vault, nunca en git.

```powershell
.\qt.ps1 secret-list qt-template-quarkus prod             # nombres de las claves cargadas
.\qt.ps1 secret-set  qt-template-quarkus prod DB_PASSWORD # pide el valor sin mostrarlo
```
