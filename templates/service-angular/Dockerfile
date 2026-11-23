####
# Imagen de runtime: Nginx sin privilegios (uid 101) sirviendo el build de Angular.
#
# El pipeline descarga el artefacto `dist` del job de build, verifica su
# SHA-256 y recién entonces lo empaqueta aquí ("build once, deploy many").
# En Kubernetes el Ingress enruta /api al backend: este contenedor solo sirve la SPA.
#
# Build local:
#   npm ci && npm run build && docker build -t qt-template-angular .
####
FROM nginxinc/nginx-unprivileged:1.30-alpine

# Config y contenido propiedad de root (solo lectura para el proceso)
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY dist/app/browser/ /usr/share/nginx/html/

EXPOSE 8080
USER 101

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
