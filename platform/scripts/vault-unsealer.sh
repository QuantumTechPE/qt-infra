#!/usr/bin/env bash
# Desella Vault automáticamente cuando se reinicia (Docker/servidor).
# SOLO PARA ENTORNOS LOCALES/LABORATORIO: la unseal key vive en disco.
# En producción real: auto-unseal con KMS (AWS/GCP/Azure) o Vault Transit.
source /scripts/lib.sh

echo "[unsealer] vigilando ${VAULT_ADDR}"
while true; do
  status="$(vcurl -s "${VAULT_ADDR}/v1/sys/seal-status" || true)"
  if [[ "$(jq -r '.initialized // false' <<<"$status" 2>/dev/null)" == "true" &&
    "$(jq -r '.sealed // false' <<<"$status" 2>/dev/null)" == "true" &&
    -s "$VAULT_INIT_FILE" ]]; then
    key="$(jq -r '.unseal_keys_b64[0]' "$VAULT_INIT_FILE")"
    if vcurl -fsS -X PUT "${VAULT_ADDR}/v1/sys/unseal" -d "$(jq -n --arg k "$key" '{key: $k}')" >/dev/null; then
      echo "[unsealer] Vault desellado $(date -u +%FT%TZ)"
    fi
  fi
  sleep 10
done
