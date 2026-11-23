#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Compone los valores de UN ambiente a partir de la carpeta deploy/ del
# microservicio (lo usan el CI para validar y la promoción GitOps):
#
#   deploy/values.yaml                 común
#   ⊕ deploy/values-<env>.yaml         plan de recursos, réplicas, HPA, PDB, ConfigMap
#   ⊕ deploy/config/<env>/*            archivos de configuración → configFiles.files
#   ⊕ deploy/vault/secrets.yaml        si declara claves → secrets.enabled=true
#   ⊕ IMAGE / DIGEST / TAG             (opcionales) imagen a desplegar
#
#   compose-values.sh <dir-del-servicio> <dev|qa|prod> [archivo-salida]
# Requiere: yq v4
# -----------------------------------------------------------------------------
set -euo pipefail

svc_dir="${1:?directorio del servicio}"
env="${2:?ambiente (dev | qa | prod)}"
out="${3:-/dev/stdout}"
d="${svc_dir%/}/deploy"

[[ " dev qa prod " == *" ${env} "* ]] || { echo "Ambiente inválido: ${env}" >&2; exit 2; }
for f in "$d/values.yaml" "$d/values-${env}.yaml"; do
  [[ -f "$f" ]] || { echo "Falta ${f}" >&2; exit 1; }
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Merge profundo (los mapas se combinan; las listas del ambiente reemplazan a las comunes).
# Se quitan los comentarios de las fuentes y los mapas quedan en estilo bloque.
yq eval-all '. as $item ireduce ({}; . * $item) | ... comments="" | (.. | select(tag == "!!map")) style=""' \
  "$d/values.yaml" "$d/values-${env}.yaml" >"$tmp"

# Archivos de configuración del ambiente → ConfigMap montado
if [[ -d "$d/config/${env}" ]]; then
  for f in "$d/config/${env}"/*; do
    [[ -f "$f" ]] || continue
    FILE="$f" NAME="$(basename "$f")" yq -i '.configFiles.files[strenv(NAME)] = load_str(strenv(FILE))' "$tmp"
  done
fi

# Secretos de Vault: se habilita el ExternalSecret solo si el servicio declara claves
keys=0
[[ -f "$d/vault/secrets.yaml" ]] && keys="$(yq '(.keys // []) | length' "$d/vault/secrets.yaml")"
KEYS="$keys" yq -i '.secrets.enabled = (env(KEYS) > 0)' "$tmp"

[[ -n "${IMAGE:-}" ]] && yq -i '.image.repository = strenv(IMAGE)' "$tmp"
[[ -n "${DIGEST:-}" ]] && yq -i '.image.digest = strenv(DIGEST)' "$tmp"
[[ -n "${TAG:-}" ]] && yq -i '.image.tag = strenv(TAG)' "$tmp"

{
  echo "# GENERADO por el pipeline de CD desde ${SOURCE:-deploy/} (${env}). No editar a mano:"
  echo "# la configuración se cambia en la carpeta deploy/ del repo del microservicio."
  cat "$tmp"
} >"$out"
