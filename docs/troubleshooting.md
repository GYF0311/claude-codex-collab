# 已知坑与修复

---

## 坑 1：Codex.app 不实时刷新外部追加的轮次

**现象**：Claude Code 通过 companion 委托的任务完成后，Codex.app 任务列表没有刷新，
需要手动切换或重启 app 才能看到新线程。

**原因**：Codex 官方已知 bug（issue #21743/#21974）。桌面 app 不会主动监听外部客户端
（非 app 自身）追加的轮次；只有用户在 app 内主动操作才会触发重读。

**修复**：委托后调用 `codex-desktop-refresh.mjs` 向 app IPC socket 广播 `query-cache-invalidate`，
触发 React Query 缓存失效，让 app 立即重新拉取任务列表。

`codex-dispatch.sh` 已在前台/后台两个路径末尾 best-effort 调用此脚本（失败静默吞掉）。

详见 [`docs/ipc-refresh.md`](ipc-refresh.md)。

---

## 坑 2：中断线程悬空 task_started 毒化 app 渲染

**现象**：某个 Codex 线程在 app 里打不开，切换/重启 app 也无效。

**原因**：每个 Codex 会话轮次在 rollout 文件中应有配对的 `task_started` + `task_complete`。
如果线程被强行中断（用户在 app 里点停止，或进程被杀），`task_complete` 来不及写入，
留下悬空的 `task_started`，导致 app hydration 出错（issue #23035/#20392/#14251）。

**修复步骤**：

```bash
# 1. 找到出问题的 rollout 文件
ls -lt ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl | head -10

# 2. 备份（必须，操作前备份）
cp ~/.codex/sessions/YYYY/MM/DD/rollout-<id>.jsonl \
   ~/.codex/backups/rollout-<id>.jsonl.bak

# 3. 检查是否有悬空 task_started
python3 - ~/.codex/sessions/YYYY/MM/DD/rollout-<id>.jsonl <<'EOF'
import json, sys
path = sys.argv[1]
starts = {}
with open(path) as f:
    for line in f:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        t = obj.get('type') or obj.get('event')
        tid = obj.get('turn_id') or obj.get('id')
        if t == 'task_started':
            starts[tid] = obj
        elif t == 'task_complete':
            starts.pop(tid, None)
print("悬空 task_started:", list(starts.keys()))
EOF

# 4. 如有悬空，向文件末尾追加合成 task_complete
# turn_id 和 agent_message 取自最后一条 agent_message 事件
python3 - ~/.codex/sessions/YYYY/MM/DD/rollout-<id>.jsonl "<turn_id>" <<'EOF'
import json, sys
from datetime import datetime, timezone

path, turn_id = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
last_msg = ""
for line in reversed(lines):
    try:
        obj = json.loads(line)
        if obj.get('type') == 'agent_message' or obj.get('role') == 'assistant':
            last_msg = obj.get('content') or obj.get('message') or ""
            break
    except Exception:
        continue

complete = {
    "type": "task_complete",
    "turn_id": turn_id,
    "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "status": "interrupted",
    "message": last_msg or "(interrupted)",
}
with open(path, "a") as f:
    f.write(json.dumps(complete, ensure_ascii=False) + "\n")
print("已追加 task_complete for turn_id:", turn_id)
EOF
```

**验证**：重新打开 Codex.app，线程应可正常渲染。

**数据层验证原则**：判断线程能否渲染不依赖截图，而是检查 rollout 文件：
- 全部行合法 JSON
- 每个 `task_started` 都有配对的 `task_complete`（无悬空）
= hydration 输入合法 = 能渲染

---

## 坑 3：effort minimal 与工具配置不兼容

**现象**：传 `--effort minimal` 给 companion 时报错约 400，任务直接失败。

**原因**：`minimal` 档位要求极简配置，与 image_gen、web_search 等工具的默认启用状态不兼容。
本机实测（Codex CLI 0.139）确认 effort 下限为 `low`，`minimal` 不可用。

**修复**：`codex-dispatch.sh` 的参数校验中已排除 `minimal`，只接受 `low|medium|high|xhigh`。
如需轻量任务，传 `--effort low` 或配合 `--model spark`（spark 模型 + low effort）。

---

## 坑 4：zsh 里 `status` 是只读保留变量

**现象**：zsh 脚本中使用 `status` 作为变量名时，出现"read-only variable"报错或静默忽略赋值。

**原因**：zsh 把 `status` 当作 `$?` 的别名（只读保留字）。

**修复**：脚本中不要使用 `status` 作为普通变量名，改用 `job_status`、`task_status`、`result_code` 等。

`codex-dispatch.sh` 和 `codex-watchdog.sh` 均已规避，不使用 `status` 变量名。

---

## 坑 5：codex exec 线程在 app 和 resume 列表不显示

**现象**：通过 `codex exec "<任务>"` 派发的任务，在 Codex.app 任务列表和 `codex resume` 选择器中都看不到。

**原因**：`codex exec` 创建的线程 `source = exec`，桌面 app 和 CLI resume picker 默认只显示
交互式来源（`cli`、`vscode`）的线程。`exec` 线程需要 `--include-non-interactive` 才能在 CLI 中列出，
app 中没有对应的 UI 入口。

**修复**：委托任务一律走 **codex-plugin-cc 官方插件通道**（即经 companion app-server），
产生的线程 `source = vscode`，两端默认可见，支持 `--resume`。

CLI resume 查看 exec 线程（仅供诊断）：

```bash
codex resume --include-non-interactive
```

---

## 坑 6：多个 watchdog 实例同时运行产生重复 settled 事件

**现象**：台账 `task-ledger.jsonl` 中出现多条 `settled` 事件。

**原因**：每次 `--bg` 委托都会启动一个新的 `codex-watchdog.sh` 进程（nohup 后台）。
如果短时间内发出多次后台委托，多个 watchdog 并发运行，各自检测到"无运行中任务"时都会写 `settled`。

**影响**：无害，只是台账有重复记录。`settled` 是只读标记，不触发任何操作。

**规避**：如不需要，可在发出第二个后台委托前，确认前一个 watchdog 已退出：

```bash
pgrep -f codex-watchdog.sh
```

---

## 查看台账（快速诊断）

```bash
# 最近 10 条事件
tail -10 ~/.codex/shared-memory/global/task-ledger.jsonl | python3 -c '
import json, sys
for line in sys.stdin:
    e = json.loads(line.strip())
    print(e["ts"][:19], e["event"].ljust(20), e.get("detail","")[:80])
'

# 只看失败/blocked 事件
grep -E '"event":"(failed|blocked|quota-exhausted)"' \
  ~/.codex/shared-memory/global/task-ledger.jsonl
```
