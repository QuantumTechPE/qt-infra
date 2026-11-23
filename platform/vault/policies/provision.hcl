# Workflow "Nuevo microservicio": SOLO puede CREAR secretos de microservicios
# (no leerlos ni sobrescribirlos). El rol JWT está atado a
# qt-infra/.github/workflows/new-service.yml en main + environment "provisioning".
path "secret/data/apps/*" {
  capabilities = ["create"]
}
