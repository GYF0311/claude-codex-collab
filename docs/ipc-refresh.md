# 桌面实时刷新机制（IPC 广播）

`codex-desktop-refresh.mjs` 在每次委托派发后，自动连接 Codex 桌面 app 的 IPC socket，
广播 `query-cache-invalidate` 事件，让 app 任务列表实时刷新，无需重启或切换线程。

---

## 为什么旧方案被废弃

### codex:// 深链（已废弃）

```bash
open "codex://threads/<thread-id>"
```

实测在某些版本的 Codex.app 中有渲染 bug——链接触发后 app 不能正确跳转或刷新。已停用。

### Open Island 灵动岛（已废弃）

安装 Open Island 后，其安装程序会把 `~/.codex/hooks.json` 改写为嵌套结构：
仅加载 Open Island 自己的 hooks，**顶层的删除护栏（rm-guard 等安全钩子）不再被加载**，
存在数据安全风险。已整体卸载，`hooks.json` 已还原。

---

## 新方案：query-cache-invalidate IPC 广播

Codex.app 在本机暴露一个 Unix domain socket，所有 IPC 通信（包括刷新任务列表）都走这里。

### socket 路径

```
$TMPDIR/codex-ipc/ipc-<uid>.sock
```

- `$TMPDIR` 通常是 `/var/folders/...` 或 `/tmp`（macOS 按用户隔离）。
- `<uid>` 是当前用户的数字 UID（`id -u` 查看，通常为 `501`）。
- 只有 Codex.app 正在运行时，此 socket 才存在。

### 帧格式

所有消息使用统一的二进制帧格式：

```
[ 4 字节 little-endian uint32（JSON 内容的字节长度） ][ UTF-8 JSON 内容 ]
```

没有分隔符，接收端需要自行处理 TCP 粘包（`FrameParser` 类实现了完整缓冲逻辑）。

### 握手与广播流程

```
客户端                        Codex.app
  │                               │
  │── connect ─────────────────►  │
  │                               │
  │── initialize(request) ──────► │   必须先握手，拿到 clientId
  │                               │
  │  ◄────── client-discovery-request（可能多次）
  │── client-discovery-response ► │   回 {canHandle: false} 继续等
  │                               │
  │  ◄────── initialize(response) │   含 clientId
  │                               │
  │── query-cache-invalidate ───► │   广播 1：刷新任务列表
  │   {queryKey: ['tasks']}        │
  │                               │
  │── query-cache-invalidate ───► │   广播 2：刷新命令菜单搜索
  │   {queryKey: ['command-menu-thread-search', 'local']}
  │                               │
  │── socket.destroy() ─────────► │
```

**为什么不能跳过 initialize？**
广播消息的 `sourceClientId` 字段需要填入服务端分配的 clientId，否则消息格式不合规。
`initialize` 握手是获取 clientId 的唯一途径。

### 消息格式示例

initialize 请求：

```json
{
  "type": "request",
  "requestId": "<uuid>",
  "sourceClientId": "claude-desktop-refresh",
  "version": 0,
  "method": "initialize",
  "params": { "clientType": "claude-desktop-refresh" }
}
```

query-cache-invalidate 广播：

```json
{
  "type": "broadcast",
  "method": "query-cache-invalidate",
  "sourceClientId": "<clientId from initialize response>",
  "version": 0,
  "params": { "queryKey": ["tasks"] }
}
```

client-discovery-response（收到 discovery request 时回复）：

```json
{
  "type": "client-discovery-response",
  "requestId": "<same as request>",
  "response": { "canHandle": false }
}
```

---

## 退出码说明

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功：广播已发送 |
| `2` | socket 不存在（Codex.app 未运行） |
| `3` | 连接超时（3000ms） |
| `4` | 流程超时（5000ms 全局看门狗） |
| `5` | socket 错误（ECONNREFUSED 等） |

`codex-dispatch.sh` 以 best-effort 方式调用此脚本：任何非零退出码都被静默吞掉，
不影响委托主流程。

---

## phase 2 评估结论（内容级实时流式渲染，暂不做）

Codex.app IPC 的 `capabilities.createThread = false`，无法通过 IPC 新建桌面线程。
`thread-follower-start-turn` 需要一个已打开的 `conversationId`，且会绕过 dispatch/ledger/watchdog 稳定层。
性价比低、比现有方案更脆弱，暂不实现。

现有方案（companion 建线程 + 刷新广播更新列表）已满足"看到任务在跑"的需求；
要看逐字流式内容时，直接在 Codex app 里打开对应线程即可。
