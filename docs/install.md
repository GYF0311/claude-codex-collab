# 安装流程

## 一、前置软件

```bash
# Codex CLI + 桌面 app（同一个 cask）
brew install --cask codex

# 登录（复用 ChatGPT 订阅，不需要额外 API key）
codex login
```

确认可用：

```bash
codex --version   # 应输出版本号，如 0.139.x
```

---

## 二、安装 codex-plugin-cc（官方 Claude Code 插件）

> 必须在 Claude Code 会话中执行，共 4 步。

**步骤 1：从 Marketplace 添加插件**

```
/plugin marketplace add openai/codex-plugin-cc
```

**步骤 2：安装插件**

```
/plugin install openai/codex-plugin-cc
```

**步骤 3：重载插件**

```
/reload-plugins
```

**步骤 4：初始化插件**

```
/codex:setup
```

完成后可用 `/codex:rescue`、`/codex:review`、`/codex:status` 等命令。

> **为什么用官方插件而不用 `codex exec`？**
>
> 官方插件走 **app-server（stdio 模式）**，线程来源（source）被硬编码为 `VSCode`，
> 因此 Codex 桌面 app **默认可见**，支持 `--resume` 原生长线程，复用 `codex login` 认证。
>
> 裸 `codex exec` 产生的线程 source = `exec`，桌面 app 和 `codex resume` 列表默认均不显示，
> 需额外传 `--include-non-interactive` 才能看到。委托日常任务建议始终走插件通道。

---

## 三、部署三个工具脚本

建议统一放在 `~/.codex/shared-memory/tools/`（与 companion 位置平级，便于后续维护）。

```bash
# 建目录
mkdir -p ~/.codex/shared-memory/tools

# 复制脚本
REPO=~/code/claude-codex-collab   # 改为你实际 clone 的路径
cp "$REPO/tools/codex-dispatch.sh"          ~/.codex/shared-memory/tools/
cp "$REPO/tools/codex-desktop-refresh.mjs"  ~/.codex/shared-memory/tools/
cp "$REPO/tools/codex-watchdog.sh"          ~/.codex/shared-memory/tools/

# 赋可执行权限
chmod +x ~/.codex/shared-memory/tools/codex-dispatch.sh
chmod +x ~/.codex/shared-memory/tools/codex-watchdog.sh
```

验证：

```bash
~/.codex/shared-memory/tools/codex-dispatch.sh --help
# 应打印 Usage: codex-dispatch.sh --cwd <project-root> ...
```

---

## 四、配置 CLAUDE.md（可选但推荐）

在你的全局 `~/.claude/CLAUDE.md` 或项目 `CLAUDE.md` 里追加以下协同节，告知 Claude Code 如何委托 Codex：

```markdown
## Claude ↔ Codex 协同

- 委托命令：`~/.codex/shared-memory/tools/codex-dispatch.sh --cwd <任务归属项目根> [--bg] [--effort <档>] "<委托单>"`
- `--cwd` 必填，传任务真正归属的项目根；不同项目的任务不要共用一个 cwd。
- effort 档：`low`（枚举/验证）、`medium`（默认，常规实现）、`xhigh`（复杂架构/深研）；下限 `low`，`minimal` 不可用。
- 后台任务加 `--bg --budget <分钟>`，脚本自动启动看门狗。
- 委托单必须带回执契约（STATUS / ARTIFACTS / BLOCKERS / NEXT）。
- 方案我出，执行优先委托 Codex；轻量琐碎改动我自办。
```

如果使用 AGENTS.md 双生机制，在 AGENTS.md 中保持同样内容，CLAUDE.md 用 `@AGENTS.md` import。

---

## 五、沙箱注意点

Codex 全局配置默认可能是 `sandbox_mode = "danger-full-access"` + `approval_policy = "never"`。
委托写任务时，在委托词中显式要求 Codex 收紧沙箱：

```
沙箱要求：限定写权限到 <工作目录>（workspace-write），不继承全局 danger-full-access。
大改任务用 git worktree 隔离。
```

`codex-dispatch.sh` 的 `--write` 标志会传递给 companion，启用写权限（需与 cwd 配合）。

---

## 六、验证安装

端到端测试（前台，约 10-30 秒）：

```bash
~/.codex/shared-memory/tools/codex-dispatch.sh \
  --cwd /tmp \
  --effort low \
  "回复一句：安装验证通过。
回执格式：
STATUS: done | blocked | failed
ARTIFACTS: none
BLOCKERS: none
NEXT: none"
```

预期输出：包含 `Thread ready (...)` 和 Codex 的回复，最后一行为 `STATUS: done`。

完成后查看台账：

```bash
tail -5 ~/.codex/shared-memory/global/task-ledger.jsonl
```

应看到包含 `dispatched`、`ack`、`done` 的三条事件记录。
