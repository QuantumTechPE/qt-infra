# qt-template-quarkus

Microservicio **Quarkus 3.40 LTS / Java 21** creado desde la plantilla de `qt-infra`.

```
src/main/java/com/qt/
  api/              recursos REST (entrada)
  application/      casos de uso
  domain/           modelo y reglas de negocio
  infrastructure/   persistencia, clientes REST, mensajería
src/main/resources/application.properties   configuración base (común)
deploy/                                      cómo corre en dev, cert y prod (ver deploy/README.md)
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

| Ambiente | Cuándo | Recursos / HPA | Configuración (repo qt-config) | Secretos (Vault) |
|---|---|---|---|---|
| dev | cada push a la rama de la historia `qt/<n>` | `deploy/values-dev.yaml` | `pre-develop`: `dev/qt-template-quarkus-dev.yaml` | `secret/apps/qt-template-quarkus/dev` |
| cert | congelamiento: cada merge a `master` (`vX.Y.Z-rc.N`, con prueba de reversión) | `deploy/values-cert.yaml` | `develop`: `cert/qt-template-quarkus-cert.yaml` | `secret/apps/qt-template-quarkus/cert` |
| prod | pase agendado y aprobado por un admin (`vX.Y.Z` al ratificar) | `deploy/values-prod.yaml` | `master`: `prod/qt-template-quarkus-prod.yaml` | `secret/apps/qt-template-quarkus/prod` |

Un cambio solo de configuración es un PR en qt-config: no necesita una versión nueva. Si el código empieza a usar una propiedad, variable o secreto nuevo, decláralo en `requiredConfig` de `deploy/values.yaml`. Ver `deploy/README.md`.

La versión publicada la define el **congelamiento** a partir de los títulos de los PRs (`feat` → minor, `fix` → patch): `vX.Y.Z-rc.N` en CERT y `vX.Y.Z` al ratificar en producción.
