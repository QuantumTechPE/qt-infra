# Vault en modo servidor con almacenamiento integrado (Raft) persistente.
# TLS con la CA interna de la plataforma (platform/.secrets/tls): los clústeres
# k3s leen secretos por la red, así que nada viaja en texto plano.
# En producción real: 3 nodos Raft + auto-unseal (KMS/Transit).

ui            = true
disable_mlock = true

api_addr     = "https://vault:8200"
cluster_addr = "https://vault:8201"

storage "raft" {
  path    = "/vault/file"
  node_id = "qt-vault-1"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/vault/tls/vault.crt"
  tls_key_file    = "/vault/tls/vault.key"
  tls_min_version = "tls12"
}
