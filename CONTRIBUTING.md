# Cómo contribuir

1. Toma una historia en estado **Ready** del tablero y **asígnatela**: el pipeline crea tu rama.
   (Para un microservicio nuevo: issue **Nuevo microservicio** en qt-infra + etiqueta `aprobado`.)
2. Trabaja en la rama `qt/<n>` que crea el pipeline (cada push despliega en DEV) y abre un PR a `master` con un título en **Conventional Commits**. La historia se enlaza sola por la rama.
3. Espera el **CI Gate** en verde y **la aprobación de un admin**: el merge es automático.
   El merge a `master` **congela** el release en CERT y abre su **issue de pase** (agenda, aprobación de admin, ejecución automática, ratificación o reversión).

Detalle completo en [docs/flujo-de-trabajo.md](docs/flujo-de-trabajo.md).
