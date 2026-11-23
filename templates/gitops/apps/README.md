# apps/

Una carpeta por microservicio, creada por el workflow *Nuevo microservicio* de `qt-infra`. Cada `apps/<servicio>/<ambiente>/values.yaml` es el **snapshot** que despliega Argo CD en ese ambiente. El pipeline de CD del servicio lo genera desde su carpeta `deploy/` más el digest de la imagen.

**No lo edites a mano**: cambia `deploy/` en el repo del servicio y promueve.
