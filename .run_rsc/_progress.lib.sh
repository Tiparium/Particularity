#!/usr/bin/env bash
set -euo pipefail

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
  local frames=('|' '/' '-' '\\')
  local use_animated=0
  if [[ -t 1 ]]; then
    use_animated=1
  fi

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$use_animated" -eq 1 ]]; then
      local frame="${frames[$((i % ${#frames[@]}))]}"
      printf "\r[%s] %s" "$frame" "$label"
      i=$((i + 1))
    elif [[ "$i" -eq 0 ]]; then
      printf "[....] %s\n" "$label"
      i=1
    fi
    sleep 0.08
  done

  wait "$pid"
  local status=$?
  if [[ $status -eq 0 ]]; then
    if [[ "$use_animated" -eq 1 ]]; then
      printf "\r[PASS] %s%*s\n" "$label" 20 ""
    else
      printf "[PASS] %s\n" "$label"
    fi
  else
    if [[ "$use_animated" -eq 1 ]]; then
      printf "\r[FAIL] %s%*s\n" "$label" 20 ""
    else
      printf "[FAIL] %s\n" "$label"
    fi
    cat "$tmp_out" >&2
  fi

  rm -f "$tmp_out"
  return $status
}
