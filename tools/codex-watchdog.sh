#!/bin/zsh
set -u

LEDGER="${HOME}/.codex/shared-memory/global/task-ledger.jsonl"
RETRY_STATE="${HOME}/.codex/shared-memory/tools/.codex-watchdog-retries.jsonl"
STALL_SECONDS=300

usage() {
  print -u2 "Usage: codex-watchdog.sh [--budget <minutes>] [--interval <seconds>]"
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

retry_count() {
  local job_id="$1"
  local thread_id="$2"
  python3 - "$RETRY_STATE" "$job_id" "$thread_id" <<'PY'
import json
import os
import sys

path, job_id, thread_id = sys.argv[1:4]
needle = thread_id or job_id
count = 0
if needle and os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if item.get("threadId") == thread_id or item.get("jobId") == job_id:
                count += 1
print(count)
PY
}

record_retry() {
  local job_id="$1"
  local thread_id="$2"
  mkdir -p "${RETRY_STATE:h}"
  python3 - "$RETRY_STATE" "$job_id" "$thread_id" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, job_id, thread_id = sys.argv[1:4]
item = {
    "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "jobId": job_id,
    "threadId": thread_id,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

extract_running_jobs() {
  python3 -c '
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

budget_minutes = int(sys.argv[1])
stall_seconds = int(sys.argv[2])
now = time.time()

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    return []

jobs = []
if isinstance(data, dict):
    for key in ("running", "jobs", "activeJobs", "trackedJobs"):
        jobs.extend(as_list(data.get(key)))
    for key in ("job", "currentJob", "activeJob"):
        value = data.get(key)
        if isinstance(value, dict):
            jobs.append(value)
    if data.get("running") is True:
        jobs.append(data)
    if data.get("status") == "running" or data.get("phase") == "running":
        jobs.append(data)
elif isinstance(data, list):
    jobs = data

seen = set()
running = []
for job in jobs:
    if not isinstance(job, dict):
        continue
    state = str(job.get("status") or job.get("state") or job.get("phase") or "running").lower()
    if state not in ("running", "active", "in_progress", "started"):
        continue
    job_id = str(job.get("jobId") or job.get("id") or job.get("job_id") or "")
    thread_id = str(job.get("threadId") or job.get("thread_id") or job.get("thread") or "")
    key = job_id or thread_id or json.dumps(job, sort_keys=True)
    if key in seen:
        continue
    seen.add(key)
    updated_at = job.get("updatedAt") or job.get("updated_at") or job.get("lastUpdate") or job.get("lastUpdatedAt")
    started_at = job.get("startedAt") or job.get("createdAt") or job.get("started_at") or job.get("created_at")
    pid = job.get("pid") or job.get("processId")
    log_file = str(job.get("logFile") or job.get("log_file") or "")

    def parse_time(value):
        if value is None:
            return None
        if isinstance(value, (int, float)):
            return value / 1000 if value > 100000000000 else float(value)
        text = str(value).strip()
        if not text:
            return None
        if text.isdigit():
            number = float(text)
            return number / 1000 if number > 100000000000 else number
        try:
            return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None

    updated_ts = parse_time(updated_at)
    started_ts = parse_time(started_at)
    elapsed = job.get("elapsed") or job.get("elapsedSeconds") or job.get("elapsedMs")
    try:
        elapsed_seconds = float(elapsed)
        if "elapsedMs" in job or elapsed_seconds > 100000:
            elapsed_seconds = elapsed_seconds / 1000
    except Exception:
        elapsed_seconds = now - started_ts if started_ts else 0

    anomalies = []
    if updated_ts and now - updated_ts > stall_seconds:
        anomalies.append("stall")
    if elapsed_seconds and elapsed_seconds > budget_minutes * 60:
        anomalies.append("overtime")
    if pid not in (None, ""):
        try:
            os.kill(int(pid), 0)
        except (OSError, ValueError):
            anomalies.append("dead")
    if log_file:
        try:
            with open(log_file, "rb") as f:
                try:
                    f.seek(-8192, os.SEEK_END)
                except OSError:
                    f.seek(0)
                tail = f.read().decode("utf-8", "ignore").lower()
            quota_terms = ("rate limit", "rate_limit", "quota", "usage limit", "insufficient_quota", "too many requests", "429")
            if any(term in tail for term in quota_terms):
                anomalies.append("quota")
        except OSError:
            pass

    running.append({
        "jobId": job_id,
        "threadId": thread_id,
        "pid": "" if pid is None else str(pid),
        "logFile": log_file,
        "elapsedSeconds": int(elapsed_seconds or 0),
        "updatedAgeSeconds": int(now - updated_ts) if updated_ts else 0,
        "anomalies": sorted(set(anomalies)),
    })

json.dump(running, sys.stdout, ensure_ascii=False, separators=(",", ":"))
' "$budget_minutes" "$STALL_SECONDS"
}

handle_retriable() {
  local companion="$1"
  local job_id="$2"
  local thread_id="$3"
  local anomaly="$4"
  local detail="$5"

  if (( $(retry_count "$job_id" "$thread_id") >= 1 )); then
    append_event "$job_id" "$thread_id" "failed" "second ${anomaly}: ${detail}"
    return
  fi

  if [[ -n "$job_id" ]]; then
    node "$companion" cancel "$job_id" >/dev/null 2>&1 || true
  fi
  node "$companion" task --resume-last --background "Watchdog retry: continue the interrupted task and return the required receipt." >/dev/null 2>&1 || true
  record_retry "$job_id" "$thread_id"
  append_event "$job_id" "$thread_id" "retried" "${anomaly}: cancelled and resumed once"
}

budget_minutes=20
interval_seconds=30

while (( $# > 0 )); do
  case "$1" in
    --budget)
      if (( $# < 2 )); then usage; exit 2; fi
      budget_minutes="$2"
      if ! [[ "$budget_minutes" == <-> ]]; then
        print -u2 "Invalid budget minutes: $budget_minutes"
        exit 2
      fi
      shift 2
      ;;
    --interval)
      if (( $# < 2 )); then usage; exit 2; fi
      interval_seconds="$2"
      if ! [[ "$interval_seconds" == <-> ]]; then
        print -u2 "Invalid interval seconds: $interval_seconds"
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

companion="$(find_companion)" || { print -u2 "codex-companion not found"; exit 1; }

while true; do
  status_json="$(node "$companion" status --json 2>/dev/null || print -r -- '{}')"
  jobs_json="$(print -r -- "$status_json" | extract_running_jobs)"
  job_count="$(print -r -- "$jobs_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || print 0)"

  if (( job_count == 0 )); then
    append_event "" "" "settled" "no running jobs"
    exit 0
  fi

  python3 -c '
import json
import sys

jobs = json.load(sys.stdin)
for job in jobs:
    detail = "elapsed=%ss updatedAge=%ss pid=%s" % (job.get("elapsedSeconds", 0), job.get("updatedAgeSeconds", 0), job.get("pid", ""))
    for anomaly in job.get("anomalies", []):
        event = "quota-exhausted" if anomaly == "quota" else anomaly
        print(job.get("jobId", ""), job.get("threadId", ""), event, detail, sep="\t")
' <<< "$jobs_json" | while IFS=$'\t' read -r job_id thread_id anomaly detail; do
    case "$anomaly" in
      quota-exhausted)
        append_event "$job_id" "$thread_id" "quota-exhausted" "$detail"
        if [[ -n "$job_id" ]]; then
          node "$companion" cancel "$job_id" >/dev/null 2>&1 || true
        fi
        ;;
      overtime)
        append_event "$job_id" "$thread_id" "overtime" "$detail"
        ;;
      stall|dead)
        append_event "$job_id" "$thread_id" "$anomaly" "$detail"
        handle_retriable "$companion" "$job_id" "$thread_id" "$anomaly" "$detail"
        ;;
    esac
  done

  sleep "$interval_seconds"
done
