#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# PR Lint: valida las convenciones que hacen funcionar la automatización.
#   1. Título en Conventional Commits  → define la próxima versión del congelamiento
#   2. Rama qt/<n>                     → la historia QT-<n> (sin historia no hay cambio)
#   3. La historia QT-<n> existe y está abierta en este repo
# El PR no cierra la historia: se cierra al ratificar el pase en producción.
# Bots (Dependabot, GitHub App) quedan exentos de 2 y 3.
#
# Entradas (variables de entorno, NUNCA interpoladas en el script):
#   PR_TITLE, PR_HEAD_REF, PR_AUTHOR, REQUIRE_ISSUE, GH_TOKEN, REPO
# -----------------------------------------------------------------------------
set -euo pipefail

: "${PR_TITLE:?PR_TITLE requerido}"
: "${PR_HEAD_REF:?PR_HEAD_REF requerido}"
: "${PR_AUTHOR:?PR_AUTHOR requerido}"
# shellcheck source=lib-project.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-project.sh"

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
# REQUIRE_ISSUE=false (repo GitOps): solo se valida el título.
require_issue="${REQUIRE_ISSUE:-true}"

if [[ "$is_bot" == false && "$require_issue" == "true" ]]; then
  code="$(code_from_branch "$PR_HEAD_REF")"
  if [[ -z "$code" ]]; then
    # 2. Rama de la historia
    errors+=("La rama \`${PR_HEAD_REF}\` no es de una historia: usa \`qt/<n>\` (la crea el pipeline al asignarte la historia ${STORY_PREFIX}-<n>).")
  else
    # 3. Historia abierta
    : "${GH_TOKEN:?}" "${REPO:?}"
    if [[ -z "$(story_by_code "$REPO" "$code" open)" ]]; then
      errors+=("No existe una historia abierta **${STORY_PREFIX}-${code}** en ${REPO}: sin historia no hay cambio.")
    fi
  fi
fi

{
  echo "## PR Lint"
  if ((${#errors[@]} == 0)); then
    echo "✅ Título, rama e historia correctos."
  else
    for e in "${errors[@]}"; do echo "- ❌ $e"; done
  fi
} >>"$summary"

if ((${#errors[@]} > 0)); then
  for e in "${errors[@]}"; do echo "::error::$e"; done
  exit 1
fi
echo "PR Lint OK"
