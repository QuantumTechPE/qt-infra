# Cómo contribuir

1. Toma una historia en estado **Ready** del tablero y **asígnatela**: el pipeline crea tu rama.
   (Para un microservicio nuevo: `bash scripts/new-service.sh <nombre> <quarkus|angular>`.)
2. Trabaja en esa rama y abre un PR con un título en **Conventional Commits** y `Closes #<n°>` en la descripción.
3. Espera el **CI Gate** en verde y **la aprobación de un admin**: el merge es automático.

Detalle completo en [docs/flujo-de-trabajo.md](docs/flujo-de-trabajo.md).
