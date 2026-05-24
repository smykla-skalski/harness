#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME_DEFAULT="${HARNESS_MONITOR_ATTRIBUTEGRAPH_PROCESS_NAME:-Harness Monitor}"
LLDB_BIN="${LLDB_BIN:-$(xcrun --find lldb 2>/dev/null || command -v lldb || true)}"

show_usage() {
  cat <<'EOF'
Usage: attach-attributegraph-breakpoint.sh [--pid PID] [--process-name NAME]

Attach LLDB to a running Harness Monitor process, break when AttributeGraph
reports a cycle via print_cycle, dump every thread backtrace, and leave the app
stopped for interactive inspection.

Examples:
  mise run monitor:debug:attributegraph
  mise run monitor:debug:attributegraph -- --pid 42866
  HARNESS_MONITOR_ATTRIBUTEGRAPH_PROCESS_NAME='Harness Monitor UI Testing' \
    mise run monitor:debug:attributegraph
EOF
}

require_lldb() {
  if [[ -n "$LLDB_BIN" && -x "$LLDB_BIN" ]]; then
    return 0
  fi
  echo "error: unable to find lldb via xcrun or PATH" >&2
  exit 127
}

resolve_pid_from_process_name() {
  local process_name="$1"
  local -a matches=()
  local pid=""
  local command=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="${line%% *}"
    command="${line#"$pid"}"
    command="${command#"${command%%[![:space:]]*}"}"
    [[ -n "$pid" ]] || continue
    if [[
      "$command" == "$process_name" ||
      "$command" == *"/Contents/MacOS/$process_name" ||
      "$command" == *"/Contents/MacOS/$process_name "* ||
      "$command" == *"/$process_name" ||
      "$command" == *"/$process_name "*
    ]]; then
      matches+=("$pid"$'\t'"$command")
    fi
  done < <(ps -axo pid=,command=)

  case "${#matches[@]}" in
    0)
      echo "error: no running process matched '$process_name'" >&2
      echo "hint: start Harness Monitor first, or pass --pid <pid>" >&2
      exit 1
      ;;
    1)
      printf '%s\n' "${matches[0]%%$'\t'*}"
      ;;
    *)
      echo "error: multiple running processes matched '$process_name'; pass --pid explicitly" >&2
      local entry
      for entry in "${matches[@]}"; do
        printf '  %s\n' "$entry" >&2
      done
      exit 1
      ;;
  esac
}

build_lldb_command_file() {
  local pid="$1"
  local command_file
  command_file="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-attributegraph.XXXXXX.lldb")"
  cat >"$command_file" <<EOF
settings set stop-disassembly-display never
process attach --pid $pid
breakpoint set --func-regex print_cycle
breakpoint command add --one-liner 'script print("\\n=== AttributeGraph cycle breakpoint hit ===\\n")'
breakpoint command add --one-liner 'thread info'
breakpoint command add --one-liner 'thread backtrace all'
breakpoint list
continue
EOF
  printf '%s\n' "$command_file"
}

main() {
  local pid=""
  local process_name="$PROCESS_NAME_DEFAULT"

  while (( $# > 0 )); do
    case "$1" in
      --pid)
        shift
        if (( $# == 0 )); then
          echo "error: --pid requires a value" >&2
          exit 2
        fi
        pid="$1"
        ;;
      --process-name)
        shift
        if (( $# == 0 )); then
          echo "error: --process-name requires a value" >&2
          exit 2
        fi
        process_name="$1"
        ;;
      -h|--help|help)
        show_usage
        exit 0
        ;;
      *)
        echo "error: unknown argument '$1'" >&2
        show_usage >&2
        exit 2
        ;;
    esac
    shift
  done

  require_lldb

  if [[ -z "$pid" ]]; then
    pid="$(resolve_pid_from_process_name "$process_name")"
  fi

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "error: pid must be numeric, got '$pid'" >&2
    exit 2
  fi

  local command_file
  command_file="$(build_lldb_command_file "$pid")"
  trap 'rm -f "$command_file"' EXIT

  printf '%s\n' \
    "info: attaching LLDB to pid $pid" \
    "info: the process will pause once for attach, then continue until print_cycle fires" \
    "info: when the breakpoint hits, LLDB prints all thread backtraces and leaves the app stopped"

  "$LLDB_BIN" -s "$command_file"
}

main "$@"
