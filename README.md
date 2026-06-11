# Claude Code × Codex 协同

> **Claude Code 主控、Codex 第二工程师** — 基于 OpenAI 官方插件 codex-plugin-cc 的本机双 Agent 协作方案。

---

## 这是什么

本仓库沉淀一套个人使用的 Claude Code × Codex 协同机制，包含：

- **架构设计**：Claude Code 作为唯一对话入口（主控），Codex（ChatGPT 订阅）作为独立第二工程师，经官方插件通道委托。
- **三个配套脚本**（`tools/`）：委托派发包装 `codex-dispatch.sh`、桌面 IPC 实时刷新 `codex-desktop-refresh.mjs`、后台任务看门狗 `codex-watchdog.sh`。
- **完整文档**（`docs/`）：安装流程、IPC 刷新原理、已知坑与修复、跨机适配指南。

---

## 架构图

```
你（用户）
  │  只跟 Claude Code 对话
  ▼
Claude Code（主控：需求澄清、方案制定、路由、终审）
  │
  ├─ 直连委托（codex-dispatch.sh）
  │    └── codex-companion.mjs  ← OpenAI codex-plugin-cc 官方插件 app-server
  │                                  └── Codex CLI / app（gpt-5.5，长 thread）
  │
  ├─ 桌面实时刷新（codex-desktop-refresh.mjs）
  │    └── Codex.app IPC socket → query-cache-invalidate 广播
  │
  └─ 后台任务看门狗（codex-watchdog.sh）
       └── 检测 stall / overtime / dead / quota-exhausted → 自动重试一次
```

---

## 前置条件

| 条件 | 说明 |
| --- | --- |
| Claude Code | 已安装并登录 |
| Codex CLI | `brew install --cask codex` 并 `codex login` |
| Codex 桌面 app | 同上，Codex.app 至少打开过一次 |
| ChatGPT 订阅 | Plus 或 Pro，复用本地认证，无需额外 API key |
| Node.js ≥ 18 | `codex-desktop-refresh.mjs` 依赖，通常随 Codex 安装 |
| Python 3 | `codex-dispatch.sh` 内嵌逻辑依赖，macOS 内置 |
| codex-plugin-cc | OpenAI 官方 Claude Code 插件（安装步骤见 `docs/install.md`） |

---

## 快速安装

```bash
# 1. 克隆本仓库到 ~/code/（或任意位置）
git clone <this-repo> ~/code/claude-codex-collab

# 2. 把三个脚本部署到共享工具目录
mkdir -p ~/.codex/shared-memory/tools
cp ~/code/claude-codex-collab/tools/codex-dispatch.sh ~/.codex/shared-memory/tools/
cp ~/code/claude-codex-collab/tools/codex-desktop-refresh.mjs ~/.codex/shared-memory/tools/
cp ~/code/claude-codex-collab/tools/codex-watchdog.sh ~/.codex/shared-memory/tools/
chmod +x ~/.codex/shared-memory/tools/codex-dispatch.sh ~/.codex/shared-memory/tools/codex-watchdog.sh

# 3. 安装官方插件（需在 Claude Code 会话中执行）
# 详见 docs/install.md
```

---

## 基本用法

### 前台委托（同步等待结果）

```bash
~/.codex/shared-memory/tools/codex-dispatch.sh \
  --cwd /path/to/your-project \
  --effort medium \
  "整理 src/utils/ 下所有函数，补充 JSDoc 注释，产物落 docs/api.md"
```

### 后台委托（长任务，自动启动看门狗）

```bash
~/.codex/shared-memory/tools/codex-dispatch.sh \
  --cwd /path/to/your-project \
  --effort xhigh \
  --bg \
  --budget 30 \
  "完整重构 auth 模块，写单测，产物落 src/auth/"
```

### 续接已有 thread（--resume-last 由 companion 处理）

委托词中说明"续接上次任务"，dispatch 脚本会把 cwd 定向到同一目录，companion 自动复用最近 thread。

### 委托单规范（建议每次带上回执契约）

```
目标：<具体要做什么>
素材：<只读输入路径>
产物：<产物格式与落点>
边界：<禁改区域>
自查要求：<完成后自验标准>

回执格式（无论成败必须返回）：
STATUS: done | blocked | failed
ARTIFACTS: <产物路径列表，无则 none>
BLOCKERS: <若 blocked/failed：原因与已尝试动作>
NEXT: <建议下一步，无则 none>
```

---

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [`docs/install.md`](docs/install.md) | 完整安装流程：插件安装 4 步、脚本部署、CLAUDE.md 配置片段、沙箱注意点 |
| [`docs/ipc-refresh.md`](docs/ipc-refresh.md) | 桌面刷新机制原理：socket 路径、帧格式、握手流程、旧方案废弃原因 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 已知坑与修复：app 不刷新、悬空 task_started、effort minimal 坑、zsh status 变量 |
| [`docs/adaptation.md`](docs/adaptation.md) | 跨机适配指南：路径替换、socket uid、effort 档位、插件版本 glob |

---

## 模型分档参考

| 场景 | 建议 effort |
| --- | --- |
| 查文件、改名、单点确认、极小改动 | 不委托，主控自办 |
| 搜索/枚举/格式核对/局部验证 | `low`（或 `--model spark`） |
| 常规单线程实现、整理、统计、批处理 | `medium`（默认） |
| 架构、深研、大实现、疑难调试、高风险迁移 | `xhigh` |
| 关键决策互验（高风险/跨系统/对外交付） | 双方独立分析后收敛 |

> `effort minimal` 与 image_gen/web_search 工具配置不兼容，下限为 `low`。

---

## 许可

MIT
