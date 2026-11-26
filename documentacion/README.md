# Documentación de la plataforma QT

Punto de entrada para operar la plataforma: qué portales hay, cómo se entra a cada uno y cómo se despliega un microservicio.

| Documento | Para qué |
|---|---|
| [portales.md](portales.md) | **Todos los portales**: URL, usuario maestro, dónde está su contraseña y cómo se generó |
| [despliegues.md](despliegues.md) | **Despliegues**: qué va en cada archivo de `deploy/`, en qt-config y en `application.properties`, y cómo se combinan |

> **Ninguna contraseña está escrita en este repositorio** (es público). Aquí se documenta el **usuario** y la **ruta de Vault** donde vive cada contraseña. Para leerlas se entra a Vault (ver [portales.md → Vault](portales.md#vault)).

## Documentación técnica detallada (carpeta `docs/`)

| Documento | Tema |
|---|---|
| [puesta-en-marcha.md](../docs/puesta-en-marcha.md) | Levantar la plataforma desde cero: GitHub, Vault, SonarQube, clústeres |
| [levantamiento.md](../docs/levantamiento.md) | Clústeres locales (k3d) y servidores definitivos (k3s + Ansible) |
| [flujo-de-trabajo.md](../docs/flujo-de-trabajo.md) | Historias, ramas `qt/<n>`, DEV, congelamiento en cert, pases a prod, reversiones |
| [configuracion.md](../docs/configuracion.md) | Repo qt-config: ConfigMaps y secretos por ambiente |
| [recursos.md](../docs/recursos.md) | CPU y RAM de clústeres, componentes y microservicios |
| [observabilidad.md](../docs/observabilidad.md) | Grafana, Prometheus, Loki, Tempo, alertas y trazas |
| [seguridad.md](../docs/seguridad.md) | Controles de seguridad del pipeline y de los clústeres |
