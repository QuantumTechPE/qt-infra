# apps/

Una carpeta por microservicio, creada por el workflow *Nuevo microservicio* de `qt-infra`. En cada `apps/<servicio>/<ambiente>/` hay dos archivos, y Argo CD despliega su combinación:

| Archivo | Qué tiene | Lo escribe |
|---|---|---|
| `values.yaml` | Snapshot **técnico**: imagen (digest), recursos, réplicas, HPA, PDB | El CD del servicio, desde su carpeta `deploy/` |
| `config.yaml` | **Configuración** del ambiente: variables, archivos y secretos declarados | El CICD de `qt-config` (y cada promoción del servicio, con la configuración vigente) |

**No los edites a mano**:
- lo técnico se cambia en `deploy/` del repo del servicio, y se promueve;
- la configuración se cambia con un PR en `qt-config`.
