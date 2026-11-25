# __GITOPS_REPO__

Fuente de verdad de **qué corre en cada clúster**. Argo CD de cada ambiente sincroniza este repo.

```
clusters/
  dev/  cert/  prod/
    addons/                       Argo CD: External Secrets, Kyverno, config de plataforma,
                                  observabilidad (Prometheus, Grafana, Loki, Alloy) y el ApplicationSet de servicios
    cluster-config.values.yaml    Vault (URL + CA), dominio del Ingress, política de imágenes
apps/
  <servicio>/
    dev/values.yaml               SNAPSHOT completo de lo que corre en dev
    cert/values.yaml                (lo escribe el pipeline de CD del servicio)
    prod/values.yaml
```

## Cómo cambia cada cosa

| Qué | Dónde se edita | Cómo llega aquí |
|---|---|---|
| Versión, plan de recursos, HPA, ConfigMaps (properties) | `deploy/` del **repo del servicio** | El pipeline de CD compone el snapshot al promover: dev en cada merge, cert y prod en cada release (prod con aprobación) |
| Secretos | **Vault** `secret/apps/<servicio>/<ambiente>` | External Secrets (nunca pasan por git) |
| Alta de un microservicio | Workflow *Nuevo microservicio* de qt-infra | PR que crea `apps/<servicio>/` (1 admin) |
| Add-ons y observabilidad del clúster | `clusters/<ambiente>/` | PR a este repo (1 admin) |

## Rollback

Revierte el commit de la promoción (`git revert <sha>`) mediante un PR. El pipeline también lo hace solo si Argo CD no queda *Healthy*.
