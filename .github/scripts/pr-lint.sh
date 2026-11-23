#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# PR Lint: valida las convenciones que hacen funcionar la automatización.
#   1. Título en Conventional Commits  → define la próxima versión (release-please)
#   2. Rama <tipo>/<issue>-<slug>       → trazabilidad historia ↔ código
#   3. "Closes #N" en la descripción    → mueve la historia en el tablero
# Bots (Dependabot, release-please) quedan exentos de 2 y 3.
#
# Entradas (variables de entorno, NUNCA interpoladas en el script):
#   PR_TITLE, PR_BODY, PR_HEAD_REF, PR_AUTHOR
# -----------------------------------------------------------------------------
set -euo pipefail

: "${PR_TITLE:?PR_TITLE requerido}"
: "${PR_HEAD_REF:?PR_HEAD_REF requerido}"
: "${PR_AUTHOR:?PR_AUTHOR requerido}"
PR_BODY="${PR_BODY:-}"

errors=()
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# 1. Conventional Commits
types='feat|fix|perf|security|refactor|docs|test|build|ci|chore|revert|style'
title_re="^(${types})(\([a-z0-9._/-]+\))?!?: .{5,}$"
if [[ ! "$PR_TITLE" =~ $title_re ]]; then
  errors+=("El título debe seguir Conventional Commits, p. ej. \`feat(api): exportar reporte en CSV\` (tipos: ${types//|/, }).")
fi

is_bot=false
[[ "$PR_AUTHOR" == *"[bot]" ]] && is_bot=true
is_release=false
[[ "$PR_HEAD_REF" == release-please--* ]] && is_release=true
# REQUIRE_ISSUE=false (repo GitOps): solo se valida el título.
require_issue="${REQUIRE_ISSUE:-true}"

if [[ "$is_bot" == false && "$is_release" == false && "$require_issue" == "true" ]]; then
  # 2. Nombre de rama
  branch_re='^(feature|fix|hotfix|chore|docs|refactor|test|ci|perf)/[0-9]+-[a-z0-9._-]+$'
  if [[ ! "$PR_HEAD_REF" =~ $branch_re ]]; then
    errors+=("La rama \`${PR_HEAD_REF}\` no cumple \`<tipo>/<n°-issue>-<slug>\` (p. ej. \`feature/42-exportar-csv\`). Asígnate la historia y el pipeline la crea por ti.")
  fi

  # 3. Vínculo a la historia
  shopt -s nocasematch
  link_re='(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+'
  if [[ ! "$PR_BODY" =~ $link_re ]]; then
    errors+=("La descripción debe vincular la historia con \`Closes #<n°>\`.")
  fi
  shopt -u nocasematch
fi

{
  echo "## PR Lint"
  if ((${#errors[@]} == 0)); then
    echo "✅ Título, rama y vínculo a la historia correctos."
  else
    for e in "${errors[@]}"; do echo "- ❌ $e"; done
  fi
} >>"$summary"

if ((${#errors[@]} > 0)); then
  for e in "${errors[@]}"; do echo "::error::$e"; done
  exit 1
fi
echo "PR Lint OK"
