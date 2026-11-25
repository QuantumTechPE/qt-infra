# Observabilidad (Grafana por ambiente)

Cada clúster (dev, cert y prod) tiene su propio stack, instalado y actualizado por GitOps desde `qt-gitops/clusters/<ambiente>/addons/`:

| Componente | Para qué | Acceso |
|---|---|---|
| **Grafana** | Dashboards, exploración de métricas y logs | `http://grafana.<dominio del ambiente>` |
| **Prometheus** + Alertmanager | Métricas de nodos, pods y microservicios; alertas | desde Grafana |
| **Loki** (SingleBinary) | Logs de todos los pods | Grafana → Explore → Loki |
| **Alloy** | Recolecta los logs de los pods y los envía a Loki | — |
| node-exporter · kube-state-metrics | Métricas de nodos y de objetos de Kubernetes | — |

La credencial de admin de Grafana es **distinta por ambiente**. Vive en Vault (`secret/platform/observability/<ambiente>`) y llega a Grafana por External Secrets:

```powershell
.\qt.ps1 vault-token     # luego, en la UI de Vault: secret/platform/observability/<ambiente>
```

## Retención por ambiente

| Ambiente | Métricas (Prometheus) | Logs (Loki) |
|---|---|---|
| dev | 3 días · 10 Gi | 72 h · 10 Gi |
| cert | 7 días · 20 Gi | 168 h · 20 Gi |
| prod | 15 días · 50 Gi | 360 h · 50 Gi |

Se ajusta en `platform/scripts/gitops-render.sh` (clústeres nuevos) o directamente en `qt-gitops/clusters/<ambiente>/addons/monitoring.yaml` y `loki.yaml` (por PR).

## Qué ve cada microservicio sin hacer nada

- **Métricas**: el chart crea un `ServiceMonitor` si `metrics.enabled: true` (backends Quarkus: `/q/metrics`, con Micrometer). Prometheus lo descubre solo.
- **Logs**: todo lo que el contenedor escribe en stdout llega a Loki con las etiquetas `namespace`, `pod`, `container`, `app` y `environment`.
- **Dashboard "QT · Microservicios"** (carpeta *QT Plataforma*), con selector de microservicio:
  - peticiones/s, % de errores 5xx y latencia media;
  - CPU y memoria por pod comparadas con el request y el límite del **plan de recursos**;
  - réplicas actuales y máximas del **HPA**, reinicios y heap de la JVM;
  - logs del microservicio.
- **Alertas** de la plataforma, además de las estándar de kube-prometheus-stack (CrashLoopBackOff, nodos, disco...):

| Alerta | Cuándo |
|---|---|
| `QTServicioSinReplicas` (critical) | Un microservicio sin pods listos durante 5 min |
| `QTTasaDeErrores5xx` | Más del 5 % de respuestas 5xx durante 10 min |
| `QTHPAEnElMaximo` | El HPA en su máximo de réplicas durante 15 min (revisar el plan de recursos) |
| `QTMemoriaCercaDelLimite` | Un pod por encima del 90 % de su límite de memoria (riesgo de OOMKilled) |

Para recibir notificaciones (Teams, Slack, correo), configura un receiver de Alertmanager en `monitoring.yaml` (`alertmanager.config`), con la URL del webhook guardada en Vault.

## Agregar dashboards

Coloca el JSON en `qt-infra/k8s/charts/observability/dashboards/`. Llega a los tres ambientes con el siguiente sync de Argo CD.
