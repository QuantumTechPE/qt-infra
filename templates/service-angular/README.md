# qt-template-angular

Frontend **Angular 22** creado desde la plantilla de `qt-infra`. Requiere **Node.js ≥ 24.15** (`.nvmrc`).

```
src/app/
  core/config/      configuración de runtime por ambiente (RuntimeConfigService)
  features/         una carpeta por funcionalidad (home/ de ejemplo)
  app.*             shell: barra superior + router
public/runtime/config.json    configuración local (en el clúster la reemplaza el ConfigMap)
deploy/                       cómo corre en dev, qa y prod (ver deploy/README.md)
```

```bash
npm ci
npm start              # http://localhost:4200 (proxy /api → http://localhost:8080)
npm run test:ci        # Vitest + cobertura LCOV
npm run format:check   # Prettier
npm run build          # dist/app/browser
```

## Ambientes

| Ambiente | Cuándo | Recursos / HPA | Configuración de runtime |
|---|---|---|---|
| dev | cada push a la rama de la historia `qt/<n>` | `deploy/values-dev.yaml` | `deploy/config/dev/config.json` |
| qa | congelamiento: cada merge a `master` (`vX.Y.Z-rc.N`, con prueba de reversión) | `deploy/values-qa.yaml` | `deploy/config/qa/config.json` |
| prod | pase agendado y aprobado por un admin (`vX.Y.Z` al ratificar) | `deploy/values-prod.yaml` | `deploy/config/prod/config.json` |

En el clúster lo sirve **Nginx sin root** con CSP estricta. La versión publicada la define el **congelamiento** (`vX.Y.Z-rc.N` en QA, `vX.Y.Z` al ratificar en producción).
