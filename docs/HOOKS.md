# 接入命令行 Agent（Hooks）

桌面版 ChatGPT / Claude / Cursor 通过辅助功能识别状态，不需要这一步。
如果你用 **Codex CLI** 或 **Claude Code** 这类命令行 Agent，可以通过它们官方的 hooks 机制把状态推给 Vibe Fishing。

`relayctl` 是 App 内附带的桥接程序：把 hooks 事件转成本机状态文件。它**不读取聊天内容、不联网、不做任何审批决定**。

官方文档：[OpenAI Codex Hooks](https://learn.chatgpt.com/docs/hooks)、[Claude Code Hooks](https://code.claude.com/docs/en/hooks)

## 适用范围

- 仅限在本机运行的 Agent 会话。云端、远程开发机或虚拟机里的会话无法访问本机收件目录。
- 推荐在 App 设置页一键安装；以下为手动方式。

## 1. 生成配置预览

```sh
RELAYCTL="/Applications/Vibe Fishing.app/Contents/MacOS/relayctl"

python3 scripts/generate-hook-config.py --source codex  --relayctl "$RELAYCTL"
python3 scripts/generate-hook-config.py --source claude --relayctl "$RELAYCTL"
```

不加 `--output` / `--install` 时只打印 JSON，不改任何文件。路径中的空格和中文会正确转义。

## 2. 安装

```sh
python3 scripts/generate-hook-config.py --source codex  --relayctl "$RELAYCTL" --install "$HOME/.codex/hooks.json"
python3 scripts/generate-hook-config.py --source claude --relayctl "$RELAYCTL" --install "$HOME/.claude/settings.json"
```

- 安装前自动在目标旁创建带时间戳的备份。
- 只更新带 `# MoyuRelay` 标记的处理器，保留你的其他 hooks 和设置；重复安装不会叠加。
- 不修改全局信任、审批模式或安全策略。

## 3. 在客户端里信任

- **Codex**：在终端运行 `codex`，输入 `/hooks`，审阅并信任这些处理器；或在桌面版 Settings → Coding → Hooks 中操作（需要本地 Codex 权限才会显示）。
- **Claude Code**：输入 `/hooks` 检查配置，遵循工作区信任流程。

未信任时客户端会跳过执行。本工具不会写入信任数据库或绕过信任。

## 4. 验证

连接完成后，在 Agent 中**新发一条消息**。App 只接受开启监听之后的新事件，旧轮次不会被追认。

## 事件映射

| 官方事件 | 状态 | 说明 |
| --- | --- | --- |
| UserPromptSubmit | running | 开始一轮 |
| PermissionRequest | needsInput | 仅 Codex；不返回同意或拒绝 |
| PostToolUse | running | 仅在等待确认之后恢复 |
| Notification | needsInput | 仅 Claude Code，等待你输入或授权 |
| Stop | completed | 同轮重复事件只投递一次 |
| Interrupt | cancelled | 仅 Codex |
| SessionEnd | cancelled | 已结束的轮次忽略 |

子任务（Subagent）事件会被忽略，不影响主会话状态。

## 事件格式

每条事件是收件目录里的一个 JSON 文件：

```json
{
  "id": "C65C26A5-BFD2-47D5-A67A-B48EF32C18CF",
  "source": "codex",
  "session_id": "session-example",
  "turn_id": "turn-example",
  "state": "completed",
  "timestamp": 1793808000.125
}
```

状态取值：`idle / running / needsInput / completed / failed / cancelled / unknown`。

## 存储与安全

- 默认收件目录：`~/Library/Application Support/MoyuRelay/inbox`，可用环境变量 `MOYU_RELAY_INBOX` 修改。
- 目录权限 0700，文件 0600，原子写入。
- 不保存 prompt、transcript 路径、工具输入或回答。
- 标准输入上限 1 MiB；非法、过大或未知事件直接丢弃。
- 无论成功与否，hook 都输出 `{}` 并以 0 退出，不会阻断 Agent。

## 开发自测

```sh
MOYU_RELAY_INBOX="$PWD/test-inbox" .build/manual/relayctl emit --source demo --state running   --session test --turn t1
MOYU_RELAY_INBOX="$PWD/test-inbox" .build/manual/relayctl emit --source demo --state completed --session test --turn t1
RELAYCTL_BIN="$PWD/.build/manual/relayctl" python3 Tests/HookBridgeTests.py
```

集成测试只使用临时目录，不修改你的 Agent 配置。
