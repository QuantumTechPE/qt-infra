#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Wrapper de gh con reintentos ante errores transitorios de GitHub. Lo cargan
# lib-project.sh (y con él todos sus scripts), admin-approvals.sh y branch-sync.sh.
# -----------------------------------------------------------------------------

# gh con reintentos ante errores TRANSITORIOS de GitHub (5xx, "Something went
# wrong while executing your query", páginas HTML de error, timeouts). La API
# (sobre todo GraphQL de Projects) falla así de vez en cuando, y un pase a
# producción no debe trabarse por eso. Los errores reales (4xx, validación)
# fallan al primer intento. La salida de un intento fallido se descarta.
GH_RETRY_RE='HTTP 5[0-9]{2}|Something went wrong|couldn.t respond to your request|invalid character .<.|timed out|timeout|connection reset|unexpected EOF|i/o timeout'
gh() {
  local attempt rc out err input="" has_input=false max="${GH_RETRIES:-5}"
  if [[ " $* " == *" --input - "* ]]; then input="$(cat)"; has_input=true; fi
  err="$(mktemp)"
  for ((attempt = 1; ; attempt++)); do
    if [[ "$has_input" == true ]]; then
      out="$(command gh "$@" 2>"$err" <<<"$input")" && rc=0 || rc=$?
    else
      out="$(command gh "$@" 2>"$err")" && rc=0 || rc=$?
    fi
    if ((rc != 0 && attempt < max)) && grep -qiE "$GH_RETRY_RE" "$err"; then
      echo "::warning::GitHub respondió con un error transitorio (intento ${attempt}/${max}): $(tr '\n' ' ' <"$err" | cut -c1-160)" >&2
      sleep $((attempt * attempt * 2))
      continue
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out"
    ((rc == 0)) || cat "$err" >&2
    rm -f "$err"
    return "$rc"
  done
}
