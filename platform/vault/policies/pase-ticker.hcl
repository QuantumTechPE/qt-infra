# Agendador local de pases (servicio pase-ticker del compose, AppRole).
# Solo LEE la agenda para saber cuándo un pase aprobado llegó a su hora. El
# despacho y el cambio de estado los hace el workflow de qt-infra (OIDC).
path "secret/metadata/platform/pases" {
  capabilities = ["list"]
}

path "secret/data/platform/pases/*" {
  capabilities = ["read"]
}

# Credencial de la GitHub App: para emitir un token de instalación acotado a
# qt-infra (contents: write) con el que envía el repository_dispatch.
path "secret/data/platform/github-app" {
  capabilities = ["read"]
}
