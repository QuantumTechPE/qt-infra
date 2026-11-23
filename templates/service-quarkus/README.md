# qt-template-quarkus

Microservicio **Quarkus 3.40 LTS / Java 21** creado desde la plantilla de `qt-infra`.

```
src/main/java/com/qt/
  api/              recursos REST (entrada)
  application/      casos de uso
  domain/           modelo y reglas de negocio
  infrastructure/   persistencia, clientes REST, mensajería
src/main/resources/application.properties   configuración base (común)
deploy/                                      cómo corre en dev, qa y prod (ver deploy/README.md)
```

| Endpoint | Uso |
|---|---|
| `GET /api/info` | Nombre, versión y ambiente (lo usa la plataforma) |
| `GET /q/health/live` · `/q/health/ready` | Probes de Kubernetes (no expuestos por el Ingress) |
| `GET /q/metrics` | Métricas para Prometheus/Grafana |

```bash
./mvnw quarkus:dev          # http://localhost:8080/api   (Dev UI: /q/dev-ui)
./mvnw verify               # tests + cobertura
```

## Ambientes

| Ambiente | Cuándo | Recursos / HPA | Properties | Secretos (Vault) |
|---|---|---|---|---|
| dev | cada merge a `main` | `deploy/values-dev.yaml` | `deploy/config/dev/` | `secret/apps/qt-template-quarkus/dev` |
| qa | cada release `vX.Y.Z` | `deploy/values-qa.yaml` | `deploy/config/qa/` | `secret/apps/qt-template-quarkus/qa` |
| prod | mismo release + aprobación de admins | `deploy/values-prod.yaml` | `deploy/config/prod/` | `secret/apps/qt-template-quarkus/prod` |

La versión (`pom.xml`, `version.txt`) la gestiona **release-please**: no la edites a mano.
