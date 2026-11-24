# Recursos (CPU y RAM) por ambiente

Dónde se configura cuánta CPU y memoria usa cada pieza, **por ambiente** (dev, qa y prod).

## Conceptos

| Campo | Qué significa | Si se excede |
|---|---|---|
| `requests.cpu` | CPU **reservada**: el scheduler solo pone el pod en un nodo que la tenga libre. `1000m` = 1 vCPU | Puede usar más si hay libre |
| `requests.memory` | RAM **reservada** en el nodo (`Mi` = mebibytes, `Gi` = gibibytes) | Puede usar más si hay libre |
| `limits.memory` | **Tope** de RAM | El pod se reinicia (*OOMKilled*) |
| `limits.cpu` | Tope de CPU (solo en los microservicios) | El proceso se ralentiza, no se reinicia |

Los componentes de plataforma usan el formato de una línea:

```yaml
resources: {requests: {cpu: 300m, memory: 2Gi}, limits: {memory: 4Gi}}
```

Hay **tres niveles**:

| Nivel | Qué es | Dónde se configura |
|---|---|---|
| [1. Tamaño del clúster](#1-tamaño-de-cada-clúster) | Las máquinas (VMs) de cada ambiente | Inventarios de Ansible + tamaño de cada VM |
| [2. Componentes de plataforma](#2-componentes-de-plataforma-por-ambiente) | Prometheus, Grafana, Loki, Alloy, Kyverno, External Secrets, Argo CD | Repo **`qt-gitops`** (y `k8s-bootstrap.sh` para Argo CD) |
| [3. Cada microservicio](#3-cada-microservicio-por-ambiente) | Los pods de cada micro | Carpeta **`deploy/`** del repo del micro |

## 1. Tamaño de cada clúster

| Ambiente | Inventario (nodos) | Sugerido para empezar |
|---|---|---|
| dev | `qt-infra/k8s/provisioning/inventories/dev/hosts.yml` | 1 nodo · 2 vCPU · 8 GB |
| qa | `qt-infra/k8s/provisioning/inventories/qa/hosts.yml` | 1 nodo · 4 vCPU · 8 GB |
| prod | `qt-infra/k8s/provisioning/inventories/prod/hosts.yml` | 3 nodos · 4 vCPU · 8 GB |

La CPU y la RAM de cada nodo son las de la VM. Para crecer, agrega nodos al inventario (sección `k3s_agent`) y ejecuta `qt k8s-provision <ambiente>`, o amplía la VM.

La base de la plataforma usa unos **0,5 vCPU y 4–4,5 GB por clúster**, medido sin microservicios (ver [levantamiento.md](levantamiento.md#0-requisitos)).

> En el servidor de pruebas (clústeres k3d en la PC) los nodos no tienen tope: comparten la CPU y la RAM que Docker Desktop tiene asignadas (*Settings → Resources*).

## 2. Componentes de plataforma, por ambiente

Se editan en el repo **`qt-gitops`**, con un **PR** (lo aprueba un admin). Al mergear, Argo CD aplica el cambio en el clúster de ese ambiente.

### Rutas exactas

| Componente | Archivo en `qt-gitops` | Clave (dentro de `spec.source.helm.valuesObject`) |
|---|---|---|
| Prometheus | `clusters/<ambiente>/addons/monitoring.yaml` | `prometheus.prometheusSpec.resources` |
| Grafana | `clusters/<ambiente>/addons/monitoring.yaml` | `grafana.resources` |
| Grafana (sidecars de dashboards) | `clusters/<ambiente>/addons/monitoring.yaml` | `grafana.sidecar.resources` |
| Alertmanager | `clusters/<ambiente>/addons/monitoring.yaml` | `alertmanager.alertmanagerSpec.resources` |
| Prometheus Operator | `clusters/<ambiente>/addons/monitoring.yaml` | `prometheusOperator.resources` |
| kube-state-metrics | `clusters/<ambiente>/addons/monitoring.yaml` | `kube-state-metrics.resources` |
| node-exporter (uno por nodo) | `clusters/<ambiente>/addons/monitoring.yaml` | `prometheus-node-exporter.resources` |
| Loki (logs) | `clusters/<ambiente>/addons/loki.yaml` | `singleBinary.resources` |
| Alloy (recolector de logs) | `clusters/<ambiente>/addons/alloy.yaml` | `alloy.resources` |
| Kyverno (admisión) | `clusters/<ambiente>/addons/kyverno.yaml` | `admissionController.container.resources` |
| Kyverno (controladores) | `clusters/<ambiente>/addons/kyverno.yaml` | `backgroundController.resources`, `cleanupController.resources`, `reportsController.resources` |
| External Secrets | `clusters/<ambiente>/addons/external-secrets.yaml` | `resources`, `webhook.resources`, `certController.resources` |

`<ambiente>` es `dev`, `qa` o `prod`. Por ejemplo, la RAM de Prometheus en producción está en `qt-gitops/clusters/prod/addons/monitoring.yaml`, línea `resources:` bajo `prometheusSpec:`.

En los mismos archivos están la **retención** y el **disco** de métricas y logs:

| Qué | Archivo | Clave | dev / qa / prod |
|---|---|---|---|
| Retención de métricas | `monitoring.yaml` | `prometheus.prometheusSpec.retention` | 3d / 7d / 15d |
| Disco de métricas | `monitoring.yaml` | `prometheus.prometheusSpec.storageSpec…storage` | 10Gi / 20Gi / 50Gi |
| Retención de logs | `loki.yaml` | `loki.limits_config.retention_period` | 72h / 168h / 360h |
| Disco de logs | `loki.yaml` | `singleBinary.persistence.size` | 10Gi / 20Gi / 50Gi |

### Valores actuales (request CPU · request RAM · límite RAM)

| Componente | dev | qa | prod |
|---|---|---|---|
| Prometheus | 100m · 1Gi · 2Gi | 200m · 1536Mi · 3Gi | 300m · 2Gi · 4Gi |
| Grafana | 50m · 384Mi · 768Mi | 50m · 384Mi · 768Mi | 100m · 512Mi · 1Gi |
| Grafana (sidecars) | 10m · 64Mi · 256Mi | 10m · 64Mi · 256Mi | 10m · 64Mi · 256Mi |
| Alertmanager | 10m · 64Mi · 128Mi | 10m · 64Mi · 128Mi | 20m · 64Mi · 256Mi |
| Prometheus Operator | 20m · 64Mi · 256Mi | 20m · 64Mi · 256Mi | 20m · 64Mi · 256Mi |
| kube-state-metrics | 10m · 64Mi · 128Mi | 10m · 64Mi · 128Mi | 20m · 64Mi · 256Mi |
| node-exporter | 10m · 32Mi · 64Mi | 10m · 32Mi · 64Mi | 10m · 32Mi · 64Mi |
| Loki | 50m · 256Mi · 512Mi | 100m · 384Mi · 1Gi | 200m · 512Mi · 2Gi |
| Alloy | 20m · 128Mi · 256Mi | 20m · 128Mi · 256Mi | 50m · 128Mi · 512Mi |
| Kyverno (admisión) | 50m · 128Mi · 384Mi | 50m · 128Mi · 384Mi | 100m · 128Mi · 512Mi |
| Kyverno (cada controlador) | 10m · 64Mi · 128Mi | 10m · 64Mi · 128Mi | 20m · 64Mi · 256Mi |
| External Secrets (cada pod) | 10m · 64Mi · 192Mi | 10m · 64Mi · 192Mi | 10m · 64Mi · 192Mi |

Si un componente se reinicia por memoria (`kubectl get pods -A` muestra `OOMKilled`), sube su `limits.memory` en el ambiente afectado.

### Argo CD

Argo CD lo instala `k8s-bootstrap.sh`, no `qt-gitops`.

| Qué | Archivo en `qt-infra` | Clave |
|---|---|---|
| Valores por ambiente | `platform/scripts/k8s-bootstrap.sh`, sección `# ---- 2. Argo CD` (bloque `case "$env"`) | `argo_controller`, `argo_repo`, `argo_server`, `argo_small` |

| Pod de Argo CD | dev y qa | prod |
|---|---|---|
| application-controller | 100m · 512Mi · 1Gi | 250m · 768Mi · 1536Mi |
| repo-server | 20m · 128Mi · 512Mi | 50m · 256Mi · 1Gi |
| server | 10m · 64Mi · 256Mi | 20m · 128Mi · 512Mi |
| applicationset-controller y redis | 10m · 64Mi · 128Mi | 10m · 64Mi · 128Mi |

Para aplicar un cambio, ejecuta de nuevo `qt k8s-bootstrap <ambiente>`; es idempotente.

### Valores iniciales para clústeres nuevos

Al generar `qt-gitops` por primera vez (`qt gitops-render`), los valores de la tabla salen de `qt-infra/platform/scripts/gitops-render.sh`, en el bloque `declare -A R=(…)` y su `case "$env"`. Cambiarlos ahí solo afecta a lo que se genere después. Para los clústeres que ya existen, edita `qt-gitops`.

## 3. Cada microservicio, por ambiente

Se editan en el **repo del microservicio**, con un PR. Viajan con la versión: DEV los recibe con el push a `qt/<n>`, QA con el congelamiento y PROD con el pase.

| Ambiente | Archivo | Claves |
|---|---|---|
| dev | `deploy/values-dev.yaml` | `resources`, `replicaCount` |
| qa | `deploy/values-qa.yaml` | `resources`, `autoscaling` |
| prod | `deploy/values-prod.yaml` | `resources`, `autoscaling`, `podDisruptionBudget`, `spreadAcrossNodes` |

```yaml
# deploy/values-prod.yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1500m
    memory: 1Gi
autoscaling:                 # HPA: réplicas según el uso
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: true
  minAvailable: 1
spreadAcrossNodes: true
```

Valores iniciales de las plantillas (request CPU · request RAM → límite CPU · límite RAM):

| Plantilla | dev | qa | prod |
|---|---|---|---|
| Backend (Quarkus) | 100m · 256Mi → 500m · 512Mi · 1 réplica | 250m · 384Mi → 1 · 768Mi · HPA 1–3 | 500m · 512Mi → 1500m · 1Gi · HPA 2–6 |
| Frontend (Angular) | 10m · 32Mi → 200m · 64Mi · 1 réplica | 20m · 32Mi → 300m · 96Mi · 1 réplica | 50m · 48Mi → 500m · 128Mi · HPA 2–4 |

Para un backend Java, `JAVA_MAX_MEM_RATIO` (en `deploy/values.yaml`, por defecto 75) define qué porcentaje del límite de memoria usa el heap.

## Cómo ver el consumo real

```bash
kubectl top nodes                        # uso por nodo
kubectl top pods -A                      # uso por pod
kubectl describe nodes | grep -A8 "Allocated resources"   # reservado (requests/limits)
```

Grafana de cada ambiente → dashboard **QT · Microservicios** (CPU, memoria y réplicas por servicio).
