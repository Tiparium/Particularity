#!/usr/bin/env bash
set -euo pipefail

progress_label() {
  local label="$1"
  local max_len="${2:-18}"
  if (( ${#label} > max_len )); then
    printf '%s...' "${label:0:$((max_len - 3))}"
  else
    printf '%s' "$label"
  fi
}

progress_render_line() {
  local prefix="$1"
  local label="$2"
  label="$(progress_label "$label")"
  printf '\r\033[2K%s %s' "$prefix" "$label" >&2
}

progress_finish_line() {
  progress_render_line "$1" "$2"
  printf '\n' >&2
}

progress_run() {
  if [[ $# -lt 2 ]]; then
    echo "progress_run requires: <label> <command...>" >&2
    return 2
  fi

  local label="$1"
  shift

  local tmp_out
  tmp_out="$(mktemp)"

  "$@" >"$tmp_out" 2>&1 &
  local pid=$!
  local i=0
  local frames=('|' '/' '-' '\')
  local use_animated=0
  if [[ -t 1 ]]; then
    use_animated=1
  fi

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$use_animated" -eq 1 ]]; then
      local frame="${frames[$((i % ${#frames[@]}))]}"
      progress_render_line "[$frame]" "$label"
      i=$((i + 1))
    elif [[ "$i" -eq 0 ]]; then
      printf "[....] %s\n" "$(progress_label "$label")" >&2
      i=1
    fi
    sleep 0.08
  done

  wait "$pid"
  local status=$?
  if [[ $status -eq 0 ]]; then
    if [[ "$use_animated" -eq 1 ]]; then
      progress_finish_line "[PASS]" "$label"
    else
      printf "[PASS] %s\n" "$(progress_label "$label")" >&2
    fi
  else
    if [[ "$use_animated" -eq 1 ]]; then
      progress_finish_line "[FAIL]" "$label"
    else
      printf "[FAIL] %s\n" "$(progress_label "$label")" >&2
    fi
    cat "$tmp_out" >&2
  fi

  rm -f "$tmp_out"
  return $status
}
