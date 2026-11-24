# Automatización de gobierno/tablero/releases: credencial de la GitHub App.
# El rol JWT que usa esta policy está atado a workflows concretos de master
# (claim job_workflow_ref), así que un PR no puede obtenerla.
path "secret/data/platform/github-app" {
  capabilities = ["read"]
}

# Contador correlativo de códigos de historia QT-<n> (check-and-set)
path "secret/data/platform/story-seq" {
  capabilities = ["create", "read", "update"]
}
