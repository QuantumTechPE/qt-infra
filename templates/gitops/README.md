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
    <ambiente>/values.yaml        snapshot TÉCNICO: imagen, recursos, HPA (lo escribe el CD del servicio)
    <ambiente>/config.yaml        CONFIGURACIÓN del ambiente (la escribe el CICD de qt-config)
```

## Cómo cambia cada cosa

| Qué | Dónde se edita | Cómo llega aquí |
|---|---|---|
| Versión, plan de recursos, HPA, PDB | `deploy/` del **repo del servicio** | El pipeline de CD compone `values.yaml` al desplegar: dev con cada push a `qt/<n>`, cert en el congelamiento y prod en el pase |
| Configuración: variables, properties / `config.json`, secretos declarados | Repo **`qt-config`** (dev ← `pre-develop`, cert ← `develop`, prod ← `master`) | Su CICD escribe `config.yaml` al mergear en la rama del ambiente |
| Secretos | **Vault** `secret/apps/<servicio>/<ambiente>` | External Secrets (nunca pasan por git) |
| Alta de un microservicio | Workflow *Nuevo microservicio* de qt-infra | PR que crea `apps/<servicio>/` (1 admin) |
| Add-ons y observabilidad del clúster | `clusters/<ambiente>/` | PR a este repo (1 admin) |

## Rollback

Revierte el commit de la promoción (`git revert <sha>`) mediante un PR. El pipeline también lo hace solo si Argo CD no queda *Healthy*.
