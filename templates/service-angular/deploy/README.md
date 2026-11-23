# deploy/: cómo corre qt-template-angular en cada ambiente

| Archivo | Qué define | Llega al pod como |
|---|---|---|
| `values.yaml` | Común: puerto, probes, ruta pública | Deployment, Service, Ingress |
| `values-dev.yaml` · `values-qa.yaml` · `values-prod.yaml` | **Plan de recursos**, réplicas, **HPA**, PDB | Deployment, HPA, PDB |
| `config/<ambiente>/config.json` | Configuración de runtime de la SPA (ambiente, URL de la API, flags) | ConfigMap servido en `/runtime/config.json` |
| `vault/secrets.yaml` | Una SPA no tiene secretos (`keys: []`) | — |

La app lee `/runtime/config.json` al iniciar (`RuntimeConfigService`), así **la misma imagen** sirve para dev, qa y prod.

En cada PR el CI valida los 3 ambientes. Al promover, el pipeline compone estos archivos en `qt-gitops/apps/qt-template-angular/<ambiente>/values.yaml`.
