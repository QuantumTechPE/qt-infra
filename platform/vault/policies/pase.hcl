# Agenda de pases a producción (una por microservicio).
# La escribe el job de aprobación (environment pase-produccion, aprobado por un
# admin) y la leen el agendador de qt-infra y la ejecución del pase. El rol JWT
# está atado a service-pase.yml y pases.yml de master de qt-infra.
path "secret/data/platform/pases/*" {
  capabilities = ["create", "read", "update"]
}
path "secret/metadata/platform/pases" {
  capabilities = ["list"]
}
path "secret/metadata/platform/pases/*" {
  capabilities = ["list", "read"]
}
