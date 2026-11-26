# Observabilidad (Grafana por ambiente)

Cada clúster (dev, cert y prod) tiene su propio stack, instalado y actualizado por GitOps desde `qt-gitops/clusters/<ambiente>/addons/`:

| Componente | Para qué | Acceso |
|---|---|---|
| **Grafana** | Dashboards, exploración de métricas, logs y trazas | `http://grafana.<dominio del ambiente>` |
| **Prometheus** + Alertmanager | Métricas de nodos, pods y microservicios; alertas | desde Grafana |
| **Loki** (SingleBinary) | Logs de todos los pods | Grafana → Explore → Loki |
| **Alloy** | Recolecta los logs de los pods y los envía a Loki | — |
| **Tempo** | Trazas OpenTelemetry de los microservicios (OTLP en `tempo.monitoring.svc:4317`) | Grafana → Explore → Tempo |
| node-exporter · kube-state-metrics | Métricas de nodos y de objetos de Kubernetes | — |

La credencial de admin de Grafana es **distinta por ambiente**. Vive en Vault (`secret/platform/observability/<ambiente>`) y llega a Grafana por External Secrets:

```powershell
.\qt.ps1 vault-token     # luego, en la UI de Vault: secret/platform/observability/<ambiente>
```

## Retención por ambiente

| Ambiente | Métricas (Prometheus) | Logs (Loki) | Trazas (Tempo) |
|---|---|---|---|
| dev | 3 días · 10 Gi | 72 h · 10 Gi | 72 h · 10 Gi |
| cert | 7 días · 20 Gi | 168 h · 20 Gi | 168 h · 20 Gi |
| prod | 15 días · 50 Gi | 360 h · 50 Gi | 360 h · 50 Gi |

Se ajusta en `platform/scripts/gitops-render.sh` (clústeres nuevos) o directamente en `qt-gitops/clusters/<ambiente>/addons/monitoring.yaml`, `loki.yaml` y `tempo.yaml` (por PR).

## Qué ve cada microservicio sin hacer nada

- **Métricas**: el chart crea un `ServiceMonitor` si `metrics.enabled: true` (backends Quarkus: `/q/metrics`, con Micrometer). Prometheus lo descubre solo.
- **Logs**: todo lo que el contenedor escribe en stdout llega a Loki con las etiquetas `namespace`, `pod`, `container`, `app` y `environment`.
- **Trazas** (backends Quarkus): la plantilla trae `quarkus-opentelemetry`, y el chart le pasa el destino (`QUARKUS_OTEL_EXPORTER_OTLP_ENDPOINT`) y el ambiente (`OTEL_RESOURCE_ATTRIBUTES`).
  - Cada petición HTTP genera una traza, con sus llamadas salientes (REST client, base de datos) como *spans*. Health y métricas (`/q/*`) no generan trazas.
  - Cada línea de log lleva `traceId=<id>`. En Grafana, desde un log de Loki se salta a su traza en Tempo (campo *TraceID*), y desde una traza a sus logs.


### Activar o desactivar por servicio

En el `deploy/values.yaml` del micro, o en `values-<ambiente>.yaml` para un solo ambiente:

```yaml
observability:
  tracing: true   # OpenTelemetry → Tempo. false: el SDK no arranca, sin consumo por trazas
  grafana: true   # métricas (Prometheus) y logs (Loki). false: el servicio no aparece en Grafana
```

| Opción | `true` | `false` |
|---|---|---|
| `tracing` | Trazas en Tempo y `traceId` en los logs | `QUARKUS_OTEL_SDK_DISABLED=true`: no se crean ni envían trazas |
| `grafana` | ServiceMonitor (métricas) y logs en Loki | Sin ServiceMonitor; el pod lleva `qt.platform/logs: "false"` y Alloy descarta sus logs (siguen en `kubectl logs`) |

Es lo técnico del micro, así que viaja con la versión: DEV → congelamiento → pase.
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
