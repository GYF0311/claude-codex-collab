#!/bin/zsh
set -u

TOOLS_DIR="${HOME}/.codex/shared-memory/tools"
LEDGER="${HOME}/.codex/shared-memory/global/task-ledger.jsonl"

usage() {
  cat >&2 <<'EOF'
Usage: codex-dispatch.sh --cwd <project-root> [--bg] [--write] [--effort <low|medium|high|xhigh>] [--budget <minutes>] "<task text>"

Required:
  --cwd <project-root>  Task's actual owning workspace root. No default.

Examples:
  corpus knowledge task:  codex-dispatch.sh --cwd "$HOME/Desktop/corpus" "..."
  edit ~/.codex:         codex-dispatch.sh --cwd "$HOME/.codex" "..."
  code project:          codex-dispatch.sh --cwd "/path/to/repo" "..."
  misc/diagnostics:      choose the most relevant workspace and pass it with --cwd
EOF
}

find_companion() {
  local -a candidates
  candidates=("${HOME}"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs(N))
  if (( ${#candidates} == 0 )); then
    return 1
  fi
  printf '%s\n' "${candidates[@]}" | python3 -c '
import os
import re
import sys

def version_key(path):
    version = os.path.basename(os.path.dirname(os.path.dirname(path)))
    return [int(part) if part.isdigit() else part for part in re.split(r"([0-9]+)", version)]

paths = [line.rstrip("\n") for line in sys.stdin if line.strip()]
print(sorted(paths, key=version_key)[-1])
'
}

append_event() {
  local job_id="$1"
  local thread_id="$2"
  local event_name="$3"
  local detail="$4"
  mkdir -p "${LEDGER:h}"
  python3 - "$LEDGER" "$job_id" "$thread_id" "$event_name" "$detail" <<'PY'
import json
import sys
from datetime import datetime, timezone

ledger, job_id, thread_id, event_name, detail = sys.argv[1:6]
event = {
    "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "jobId": job_id,
    "threadId": thread_id,
    "event": event_name,
    "detail": detail,
}
with open(ledger, "a", encoding="utf-8") as f:
    f.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

extract_thread_id() {
  python3 -c '
import re
import sys

text = sys.stdin.read()
patterns = [
    r"Thread ready\s*\(([^)]+)\)",
    r"Thread ready[^\n]*\bthread(?:Id|ID| id)?[:= ]+([A-Za-z0-9_-]+)",
    r"threadId.{0,3}([0-9a-f-]{36})",
]
for pattern in patterns:
    match = re.search(pattern, text, re.IGNORECASE)
    if match:
        print(match.group(1))
        break
'
}

last_nonempty_line() {
  python3 -c '
import sys

lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
print(lines[-1][:300] if lines else "")
'
}

# 从任意字符串里抽出第一个 UUID(36位 hex-dash),没有则空。用于台账记录干净 threadId。
sanitize_tid() {
  print -r -- "$1" | python3 -c '
import re, sys
m = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", sys.stdin.read())
print(m.group(0) if m else "")
'
}

# bg 模式:companion 输出只有 job id,查 status 拿 threadId(清洗成单个 UUID)
thread_id_for_job() {
  local companion="$1" job_id="$2"
  [[ -z "$job_id" ]] && return 0
  local tries=0 raw tid
  while (( tries < 8 )); do
    raw="$(node "$companion" status --json 2>/dev/null | python3 -c '
import json, sys
jid = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: d = {}
for j in d.get("running", []) + ([d.get("latestFinished")] if d.get("latestFinished") else []):
    if j and j.get("id") == jid:
        print(j.get("threadId") or ""); break
' "$job_id")"
    tid="$(sanitize_tid "$raw")"
    if [[ -n "$tid" ]]; then print -r -- "$tid"; return 0; fi
    sleep 1; (( tries++ ))
  done
}

# best-effort:派发后戳一下桌面 Codex.app 让它实时刷新任务列表。
# 失败(app 没开/socket 不在/超时)一律吞掉,绝不影响派发主流程。
refresh_desktop() {
  command -v node >/dev/null 2>&1 || return 0
  [[ -f "${TOOLS_DIR}/codex-desktop-refresh.mjs" ]] || return 0
  node "${TOOLS_DIR}/codex-desktop-refresh.mjs" >/dev/null 2>&1 || true
}

background=0
write_flag=0
effort="medium"
model=""
budget_minutes=20
task_text=""
task_cwd=""

while (( $# > 0 )); do
  case "$1" in
    --bg)
      background=1
      shift
      ;;
    --write)
      write_flag=1
      shift
      ;;
    --cwd)
      if (( $# < 2 )); then usage; exit 2; fi
      task_cwd="$2"
      shift 2
      ;;
    --effort)
      if (( $# < 2 )); then usage; exit 2; fi
      effort="$2"
      case "$effort" in
        low|medium|high|xhigh) ;;
        *) print -u2 "Invalid effort: $effort"; exit 2 ;;
      esac
      shift 2
      ;;
    --model)
      if (( $# < 2 )); then usage; exit 2; fi
      model="$2"
      shift 2
      ;;
    --budget)
      if (( $# < 2 )); then usage; exit 2; fi
      budget_minutes="$2"
      if ! [[ "$budget_minutes" == <-> ]]; then
        print -u2 "Invalid budget minutes: $budget_minutes"
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      print -u2 "Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      if [[ -n "$task_text" ]]; then
        print -u2 "Only one task text argument is supported"
        usage
        exit 2
      fi
      task_text="$1"
      shift
      ;;
  esac
done

if [[ -z "$task_text" ]]; then
  usage
  exit 2
fi

if [[ -z "$task_cwd" ]]; then
  print -u2 "Error: --cwd is required. Pass the project root that actually owns this task; there is no corpus default."
  usage
  exit 2
fi

if [[ ! -d "$task_cwd" ]]; then
  print -u2 "cwd not a directory: $task_cwd"
  usage
  exit 2
fi

companion="$(find_companion)" || { print -u2 "codex-companion not found"; exit 1; }

mode="fg"
(( background )) && mode="bg"
append_event "" "" "dispatched" "mode=${mode}; effort=${effort}; model=${model:-default}; budget=${budget_minutes}m"

cmd=(node "$companion" task --effort "$effort")
[[ -n "$model" ]] && cmd+=(--model "$model")
(( background )) && cmd+=(--background)
(( write_flag )) && cmd+=(--write)
cmd+=("$task_text")

# 从 task_cwd 跑 companion,线程项目归属固定,不随调用方 PWD 漂移
output="$(cd "$task_cwd" && "${cmd[@]}" 2>&1)"
exit_code=$?
thread_id="$(print -r -- "$output" | extract_thread_id)"
summary="$(print -r -- "$output" | last_nonempty_line)"

job_id="$(print -r -- "$output" | python3 -c '
import re, sys
m = re.search(r"as (task-[a-z0-9-]+)", sys.stdin.read())
print(m.group(1) if m else "")
')"

if [[ -n "$thread_id" || -n "$job_id" ]]; then
  append_event "$job_id" "$thread_id" "ack" "companion accepted"
else
  append_event "" "" "ack" "no thread/job id found in companion output"
fi

print -r -- "$output"

if (( background )); then
  bg_thread_id="$(thread_id_for_job "$companion" "$job_id")"
  if [[ -n "$bg_thread_id" ]]; then
    append_event "$job_id" "$bg_thread_id" "thread" "resolved threadId for bg job"
  fi
  nohup "${TOOLS_DIR}/codex-watchdog.sh" --budget "$budget_minutes" >>"${TOOLS_DIR}/codex-watchdog.log" 2>&1 &
  print -r -- "codex-watchdog started with budget=${budget_minutes}m"
  refresh_desktop
else
  if (( exit_code == 0 )); then
    append_event "$job_id" "$thread_id" "done" "$summary"
  else
    append_event "$job_id" "$thread_id" "failed" "$summary"
  fi
  refresh_desktop
fi

exit "$exit_code"
