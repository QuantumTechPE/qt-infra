#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Compone los valores TÉCNICOS de UN ambiente a partir de la carpeta deploy/ del
# microservicio (lo usan el CI para validar y la promoción GitOps):
#
#   deploy/values.yaml                 común (puerto, probes, Ingress, métricas)
#   ⊕ deploy/values-<env>.yaml         plan de recursos, réplicas, HPA, PDB
#   ⊕ IMAGE / DIGEST / TAG             (opcionales) imagen a desplegar
#
# La CONFIGURACIÓN del ambiente (variables, archivos y secretos declarados) NO
# sale de aquí: vive en el repo qt-config y su CD la escribe aparte, en
# qt-gitops/apps/<servicio>/<env>/config.yaml. Por eso se quitan del snapshot
# config, configFiles.files y secrets.enabled (también los de versiones viejas).
#
#   compose-values.sh <dir-del-servicio> <dev|cert|prod> [archivo-salida]
# Requiere: yq v4
# -----------------------------------------------------------------------------
set -euo pipefail

svc_dir="${1:?directorio del servicio}"
env="${2:?ambiente (dev | cert | prod)}"
out="${3:-/dev/stdout}"
d="${svc_dir%/}/deploy"

[[ " dev cert prod " == *" ${env} "* ]] || { echo "Ambiente inválido: ${env}" >&2; exit 2; }
env_file="$d/values-${env}.yaml"
# Versiones anteriores al renombre qa → cert (p. ej. la que restaura una
# reversión) traen values-qa.yaml: se usa como el plan de recursos de cert.
if [[ "$env" == "cert" && ! -f "$env_file" && -f "$d/values-qa.yaml" ]]; then
  echo "ℹ️ ${d}: versión anterior al renombre qa → cert; se usa values-qa.yaml" >&2
  env_file="$d/values-qa.yaml"
fi
for f in "$d/values.yaml" "$env_file"; do
  [[ -f "$f" ]] || { echo "Falta ${f}" >&2; exit 1; }
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Merge profundo (los mapas se combinan; las listas del ambiente reemplazan a las comunes).
# Se quitan los comentarios de las fuentes y los mapas quedan en estilo bloque.
yq eval-all '. as $item ireduce ({}; . * $item) | ... comments="" | (.. | select(tag == "!!map")) style=""' \
  "$d/values.yaml" "$env_file" >"$tmp"

# Fuera del snapshot técnico: la configuración la pone qt-config (config.yaml)
yq -i 'del(.config) | del(.configFiles.files) | del(.secrets.enabled) | del(.requiredConfig)' "$tmp"

[[ -n "${IMAGE:-}" ]] && yq -i '.image.repository = strenv(IMAGE)' "$tmp"
[[ -n "${DIGEST:-}" ]] && yq -i '.image.digest = strenv(DIGEST)' "$tmp"
[[ -n "${TAG:-}" ]] && yq -i '.image.tag = strenv(TAG)' "$tmp"

{
  echo "# GENERADO por el pipeline de CD desde ${SOURCE:-deploy/} (${env}). No editar a mano:"
  echo "# lo técnico se cambia en deploy/ del microservicio; la configuración, en qt-config."
  cat "$tmp"
} >"$out"
