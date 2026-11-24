#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Releases del pase a producción (GitHub Releases + tags inmutables).
#
#   release.sh freeze
#       Congelamiento de master. Crea:
#         · release del CAMBIO     vX.Y.Z-rc.N            (lo que irá a producción)
#         · release de REVERSIÓN   vX.Y.Z-rc.N-reversion  (lo que hoy corre en
#           producción, según qt-gitops; "retiro" si aún no hay nada)
#       Cada release lleva despliegue.json (imagen, digest, commit).
#       La versión sale de los commits desde el último release final:
#       feat → minor, fix/otros → patch, "!"/BREAKING CHANGE → major (minor en 0.x).
#
#   release.sh final <tag-del-cambio>
#       Ratificación: publica vX.Y.Z (latest) en el mismo commit, con las notas
#       desde el release final anterior y los artefactos del congelamiento.
#
# Entradas: GH_TOKEN (GitHub App: contents del repo + lectura de qt-gitops),
#           REPO, GITHUB_SHA, SERVICE, GITOPS_REPO (owner/repo)
#           IMAGE, DIGEST (solo freeze: la imagen recién construida)
# Requiere el checkout del repo con historial completo (fetch-depth: 0).
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GH_TOKEN:?}" "${REPO:?}" "${GITHUB_SHA:?}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"
mode="${1:?freeze | final <tag>}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git fetch --quiet --force --tags origin
FINAL_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

last_final() { git tag -l 'v*' --merged "$GITHUB_SHA" | grep -E "$FINAL_RE" | sort -V | tail -n1 || true; }

next_version() {
  local base="${1#v}" range="$2" major minor patch level=patch
  IFS=. read -r major minor patch <<<"$base"
  if git log --format='%s' $range | grep -qE '^[a-z]+(\([^)]*\))?!:' ||
    git log --format='%b' $range | grep -q '^BREAKING CHANGE'; then
    level=major
  elif git log --format='%s' $range | grep -qE '^feat(\([^)]*\))?:'; then
    level=minor
  fi
  [[ "$level" == major && "$major" == 0 ]] && level=minor # semver 0.x
  case "$level" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
  esac
}

# notes <rango> → Markdown: historias incluidas + cambios por tipo
notes() {
  local range="$1" subject type code n title url
  local -A section=([feat]="" [fix]="" [perf]="" [security]="" [refactor]="" [otros]="")
  while IFS= read -r subject; do
    [[ -z "$subject" ]] && continue
    type="$(sed -nE 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/p' <<<"$subject")"
    [[ -n "${section[$type]+x}" ]] || type=otros
    section[$type]+="- ${subject}"$'\n'
  done < <(git log --format='%s' $range)

  echo "### Historias"
  local any=false
  while read -r code; do
    [[ -z "$code" ]] && continue
    read -r _ n title <<<"$(story_by_code "$REPO" "$code" all)" || true
    [[ -z "${n:-}" ]] && continue
    any=true
    url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/issues/${n}"
    echo "- [${title}](${url})"
  done < <(stories_in_range "$REPO" "$range")
  [[ "$any" == true ]] || echo "- (sin historias: solo mantenimiento)"
  echo
  local -A heading=([feat]="Funcionalidades" [fix]="Correcciones" [perf]="Rendimiento"
    [security]="Seguridad" [refactor]="Refactorizaciones" [otros]="Otros cambios")
  for type in feat fix perf security refactor otros; do
    [[ -n "${section[$type]}" ]] && printf '### %s\n%s\n' "${heading[$type]}" "${section[$type]}"
  done
}

# despliegue.json de un release (vacío si no existe)
release_deploy_json() {
  rm -f "$work/despliegue.json"
  gh release download "$1" --repo "$REPO" --pattern despliegue.json --dir "$work" >/dev/null 2>&1 || true
  cat "$work/despliegue.json" 2>/dev/null || true
}

case "$mode" in
  # ------------------------------------------------------------------ congelamiento
  freeze)
    : "${IMAGE:?}" "${DIGEST:?}" "${SERVICE:?}" "${GITOPS_REPO:?}"
    lf="$(last_final)"
    range="${lf:+${lf}..}${GITHUB_SHA}"

    # Re-ejecución del mismo commit: se reutiliza su congelamiento
    tag="$(git tag -l 'v*-rc.*' --points-at "$GITHUB_SHA" | grep -E -- '-rc\.[0-9]+$' | sort -V | tail -n1 || true)"
    if [[ -z "$tag" ]]; then
      version="$(next_version "${lf:-v0.0.0}" "$range")"
      n="$(git tag -l "v${version}-rc.*" | grep -cE -- "-rc\.[0-9]+$" || true)"
      tag="v${version}-rc.$((n + 1))"
    fi
    version="${tag%-rc.*}"
    reversion_tag="${tag}-reversion"

    # Lo que corre HOY en producción (qt-gitops) = lo que restaura la reversión
    prod="$(gh api "repos/${GITOPS_REPO}/contents/apps/${SERVICE}/prod/values.yaml?ref=master" --jq '.content' | base64 -d)"
    rev_digest="$(yq '.image.digest // ""' <<<"$prod")"
    rev_image="$(yq '.image.repository // ""' <<<"$prod")"
    rev_label="$(yq '.image.tag // ""' <<<"$prod")"
    rev_commit="$(sed -nE '1s/.*@([0-9a-f]{40}).*/\1/p' <<<"$prod")"
    if [[ -z "$rev_digest" ]]; then
      rev_label="retiro"
      rev_commit="$GITHUB_SHA" # nada que restaurar: la reversión retira el servicio
      rev_image="$IMAGE"
    fi

    notes "$range" >"$work/notes.md"
    jq -n --arg tag "$tag" --arg image "$IMAGE" --arg digest "$DIGEST" --arg commit "$GITHUB_SHA" \
      '{tag: $tag, image: $image, digest: $digest, commit: $commit}' >"$work/despliegue.json"
    if ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
      {
        echo "**Release del cambio** congelado para QA. Pasa a producción con su issue de pase."
        echo
        echo "- Imagen: \`${IMAGE}@${DIGEST}\`"
        echo "- Reversión: \`${reversion_tag}\` (restaura **${rev_label}**)"
        echo
        cat "$work/notes.md"
      } >"$work/body.md"
      gh release create "$tag" --repo "$REPO" --target "$GITHUB_SHA" --prerelease \
        --title "${tag} · cambio" --notes-file "$work/body.md" "$work/despliegue.json" >/dev/null
    fi

    mkdir -p "$work/rev"
    jq -n --arg tag "$reversion_tag" --arg image "$rev_image" --arg digest "$rev_digest" \
      --arg commit "$rev_commit" --arg restaura "$rev_label" --arg de "$tag" \
      '{tag: $tag, image: $image, digest: $digest, commit: $commit, restaura: $restaura, revierte: $de}' >"$work/rev/despliegue.json"
    if ! gh release view "$reversion_tag" --repo "$REPO" >/dev/null 2>&1; then
      if [[ "$rev_label" == "retiro" ]]; then
        rev_body="**Release de reversión** de \`${tag}\`: aún no hay versión en producción, así que revertir **retira** el servicio."
      else
        rev_body="**Release de reversión** de \`${tag}\`: restaura **${rev_label}** (\`${rev_image}@${rev_digest}\`), lo que corre hoy en producción, con la configuración de su commit."
      fi
      gh release create "$reversion_tag" --repo "$REPO" --target "$rev_commit" --prerelease \
        --title "${reversion_tag} · reversión" --notes "$rev_body" "$work/rev/despliegue.json" >/dev/null
    fi

    {
      echo "tag=${tag}"
      echo "version=${version}"
      echo "reversion_tag=${reversion_tag}"
      echo "reversion_image=${rev_image}"
      echo "reversion_digest=${rev_digest}"
      echo "reversion_commit=${rev_commit}"
      echo "reversion_label=${rev_label}"
      echo "stories=$(stories_in_range "$REPO" "$range" | paste -sd' ' -)"
    } >>"$out"
    {
      echo "### Congelamiento"
      echo "- Cambio: \`${tag}\` (\`${DIGEST:0:19}…\`)"
      echo "- Reversión: \`${reversion_tag}\` → ${rev_label}"
    } >>"$summary"
    ;;

  # ------------------------------------------------------------------ ratificación
  final)
    change="${2:?tag del release del cambio (vX.Y.Z-rc.N)}"
    version="${change%-rc.*}"
    commit="$(git rev-list -n1 "$change")"
    if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
      [[ "$(git rev-list -n1 "$version")" == "$commit" ]] ||
        { echo "::error::${version} ya existe en otro commit"; exit 1; }
    else
      lf="$(GITHUB_SHA="$commit" last_final)"
      notes "${lf:+${lf}..}${commit}" >"$work/notes.md"
      mkdir -p "$work/assets"
      gh release download "$change" --repo "$REPO" --dir "$work/assets" >/dev/null 2>&1 || true
      shopt -s nullglob
      assets=("$work"/assets/*)
      gh release create "$version" --repo "$REPO" --target "$commit" --latest \
        --title "$version" --notes-file "$work/notes.md" "${assets[@]}" >/dev/null
    fi
    echo "tag=${version}" >>"$out"
    echo "### Release final: \`${version}\` (desde \`${change}\`)" >>"$summary"
    ;;

  *)
    echo "Modo desconocido: $mode" >&2
    exit 2
    ;;
esac
