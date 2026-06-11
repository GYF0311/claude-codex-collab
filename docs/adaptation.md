# 跨机适配指南

本方案在 macOS 上开发和验证。以下是在其他机器或用户环境中使用时需要关注的适配点。

---

## 1. 路径替换

脚本中的所有路径均使用 `$HOME` 环境变量，无写死的用户名。部署时只需保证：

| 路径 | 说明 |
| --- | --- |
| `$HOME/.codex/shared-memory/tools/` | 脚本部署目录（可自定义，但需同步修改 `TOOLS_DIR`） |
| `$HOME/.codex/shared-memory/global/task-ledger.jsonl` | 任务台账（自动创建） |
| `$HOME/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` | codex-plugin-cc 安装后的 companion 脚本（通配 glob） |

如果你把脚本放在非默认位置，修改 `codex-dispatch.sh` 顶部的 `TOOLS_DIR` 变量：

```bash
TOOLS_DIR="/your/custom/path/tools"
```

---

## 2. IPC socket 路径与用户 UID

`codex-desktop-refresh.mjs` 默认 socket 路径：

```javascript
path.join(os.tmpdir(), 'codex-ipc', `ipc-${process.getuid()}.sock`)
```

- `os.tmpdir()`：macOS 上通常是 `/var/folders/xx/xxx/T`，Linux 上通常是 `/tmp`。
- `process.getuid()`：当前用户数字 UID（`id -u` 查看）。

如果 socket 路径不同（如 Codex 使用了非默认配置），可以通过环境变量或命令行参数覆盖：

```bash
# 环境变量方式
CODEX_IPC_SOCK=/custom/path/ipc.sock node codex-desktop-refresh.mjs

# 命令行参数方式
node codex-desktop-refresh.mjs --socket /custom/path/ipc.sock
```

验证 socket 是否存在（Codex.app 运行时）：

```bash
ls -la "$TMPDIR/codex-ipc/"
# 应看到 ipc-<uid>.sock
```

---

## 3. companion 脚本路径（插件版本 glob）

`codex-dispatch.sh` 和 `codex-watchdog.sh` 通过 glob 自动定位最新版 companion：

```bash
${HOME}/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs
```

如果 codex-plugin-cc 的安装路径不同（如使用非标准 Claude Code 安装），修改 `find_companion()` 函数中的 glob 模式。

查看当前实际路径：

```bash
ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs
```

---

## 4. effort 档位

`--effort` 的合法值：`low | medium | high | xhigh`

- **`minimal` 不可用**：与 image_gen/web_search 工具配置不兼容，传入会导致约 400 错误。下限是 `low`。
- `codex-dispatch.sh` 默认档位是 `medium`（不传 `--effort` 时）。
- 如果你的 Codex 配置中没有启用 web_search/image_gen 等工具，`minimal` 可能可用，但未验证。

---

## 5. --cwd 语义

`--cwd` 传入的是**任务真正归属的项目根目录**，companion 会以此目录为 workspace 运行任务：

- Codex 的 sandbox `writable_roots` 以此目录为基准。
- 线程在 app 中按此目录分组显示（app 侧边栏"按项目组织"模式）。
- 不同项目的任务**不要共用 cwd**，否则线程归属混乱，sandbox 写权限也不对。

示例：

```bash
# 知识库任务 → 知识库根目录
codex-dispatch.sh --cwd ~/Desktop/my-corpus "..."

# 代码项目任务 → 代码仓库根
codex-dispatch.sh --cwd ~/code/my-repo "..."

# 修改 Codex 自己的配置 → ~/.codex
codex-dispatch.sh --cwd ~/.codex "..."

# 诊断/临时任务 → 选一个合适的目录，不要随便用 /tmp
codex-dispatch.sh --cwd ~ "..."
```

---

## 6. Linux 适配注意点

本方案在 macOS 上开发，Linux 用户需注意：

- **zsh**：脚本头部是 `#!/bin/zsh`，Linux 上需确保 zsh 已安装（`apt install zsh` 或 `brew install zsh`），或改为 `#!/bin/bash`（需测试 zsh 特有语法）。
- **tmpdir**：Linux 上 `$TMPDIR` 通常是 `/tmp`，socket 路径对应 `/tmp/codex-ipc/ipc-<uid>.sock`。
- **`process.getuid()`**：Linux 上可用，Windows 不可用（`codex-desktop-refresh.mjs` 在 Windows 上需额外适配）。
- **trash 命令**：脚本本身不调用 `trash`，但文档中提到的删除操作在 Linux 上需改用 `gio trash` 或 `trash-cli`。

---

## 7. 多用户/多工作区场景

如果一台机器有多个用户，每个用户独立安装 Codex 和插件，各自的：
- socket 路径（不同 uid）
- companion 路径（不同 `$HOME`）
- 台账路径（不同 `$HOME`）

互不干扰，脚本天然支持（全部基于 `$HOME`）。

---

## 8. Codex CLI 版本兼容性

已验证版本：**Codex CLI 0.139.x**，Codex.app 26.608.12217。

`codex-dispatch.sh` 通过 `codex-companion.mjs` 的 `task` / `status` 命令与 Codex 通信。
如果升级 Codex 后 companion 接口变化，以下命令可查看当前 companion 版本和可用命令：

```bash
node "$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs | tail -1)" --help
```

升级 Codex CLI：

```bash
brew upgrade --cask codex
```

升级后重新运行 `/codex:setup` 重新初始化插件。
