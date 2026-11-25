#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Promoción de qt-config entre ramas (en orden): pre-develop → develop → master.
# Tras cada merge en pre-develop (o develop) abre o actualiza el PR hacia la
# rama siguiente, con la lista de cambios por ambiente. Un admin lo aprueba y se
# mergea solo (merge commit, para que las ramas compartan historia).
#
#   config-promotion.sh <rama-que-recibió-el-push>
# Entradas: GH_TOKEN (GitHub App con escritura en qt-config), REPO (owner/repo)
# -----------------------------------------------------------------------------
set -euo pipefail
# shellcheck source=lib-gh.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-gh.sh"
# shellcheck source=config-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/config-lib.sh"

: "${GH_TOKEN:?}" "${REPO:?}"
head="${1:?rama}"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
case "$head" in
  pre-develop) base=develop ;;
  develop) base=master ;;
  *) echo "La rama ${head} no se promueve (solo pre-develop → develop → master)."; exit 0 ;;
esac
target_env="$(config_env_of_branch "$base")"

compare="$(gh api "repos/${REPO}/compare/${base}...${head}")"
ahead="$(jq -r '.ahead_by' <<<"$compare")"
# Solo los commits con cambios reales (los merge commits de promociones previas no cuentan)
changes="$(jq -r '[.files[]?.filename] | length' <<<"$compare")"
existing="$(gh api "repos/${REPO}/pulls?state=open&head=${REPO%/*}:${head}&base=${base}" --jq '.[0].number // empty')"

if [[ "$ahead" == "0" || "$changes" == "0" ]]; then
  echo "✔ ${base} ya tiene todo lo de ${head}: nada que promover." | tee -a "$summary"
  exit 0
fi

files_md="$(jq -r '.files[] | "- `\(.filename)` (\(.status))"' <<<"$compare")"
commits_md="$(jq -r '.commits[] | select((.parents | length) == 1) | "- \(.commit.message | split("\n")[0]) (\(.sha[0:7]))"' <<<"$compare")"
body="$(cat <<EOF
Promoción automática de **${head}** → **${base}**: al mergear, **${target_env}** toma la configuración de \`${target_env}/\` (CICD ${target_env^^}).

### Archivos
${files_md}

### Cambios
${commits_md}

> Las carpetas de los otros ambientes viajan también, pero cada ambiente solo lee la suya desde su rama: \`dev/\` ← pre-develop, \`cert/\` ← develop, \`prod/\` ← master.

🤖 Generado por la plataforma (qt-infra).
EOF
)"

if [[ -n "$existing" ]]; then
  gh api -X PATCH "repos/${REPO}/pulls/${existing}" -f body="$body" >/dev/null
  echo "🔄 PR de promoción #${existing} actualizado (${head} → ${base})." | tee -a "$summary"
else
  url="$(gh api -X POST "repos/${REPO}/pulls" -f head="$head" -f base="$base" \
    -f title="chore(config): promover ${head} → ${base} (${target_env})" -f body="$body" --jq '.html_url')"
  echo "🆕 PR de promoción: ${url}" | tee -a "$summary"
fi
