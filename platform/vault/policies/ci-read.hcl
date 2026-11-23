# CI (cualquier workflow del repo, incluidos PRs internos):
# solo credenciales de herramientas de análisis.
path "secret/data/ci/*" {
  capabilities = ["read"]
}
