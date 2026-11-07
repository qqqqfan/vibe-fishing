# Vibe Fishing

**vibe coding 间隙摸鱼助手。** AI 在干活时，iPhone 镜像里的竖屏短视频自动播放；AI 完成或需要你确认时，视频自动暂停。

> A macOS menu-bar utility that plays short videos in iPhone Mirroring while your AI agent is working, and pauses them the moment it finishes or needs your input.

<!-- TODO: 在这里放一段 15 秒演示动图 docs/demo.gif -->

## 它做什么

1. 监听 AI 应用的状态：生成中 / 已完成 / 等待你确认。
2. 在 macOS 自带的 **iPhone 镜像**里，替你点击播放和暂停。
3. 把 AI 窗口和镜像并排铺开，镜像上方留一条状态小窗。

你在 AI 输入框里打字时，它会等你按下发送再动手，不会把光标抢走。

## 系统要求

| 项目 | 要求 |
|---|---|
| Mac | macOS 15 及以上，支持 iPhone 镜像的机型 |
| iPhone | iOS 18 及以上，与 Mac 登录同一 Apple 账户并开启双重认证 |
| 地区 | iPhone 镜像在欧盟地区不可用 |
| AI 应用 | ChatGPT / Codex、Claude、Cursor；也可在设置中添加其他应用 |
| 命令行 Agent | Codex CLI、Claude Code（可选，通过 hooks 接入，见 [docs/HOOKS.md](docs/HOOKS.md)） |

手机上任何支持竖屏信息流的视频 App 都可以用，建议在 App 内开启「自动连播」。

## 安装

从 [Releases](../../releases) 下载最新的 `Vibe Fishing.dmg`，拖进「应用程序」即可。

首次打开会依次引导你：授权 → 选择 AI 应用 → 连接 iPhone 镜像 → 打开短视频 → 排列窗口。

## 需要的权限与用途

| 权限 | 用途 |
|---|---|
| 辅助功能 | 读取 AI 应用界面上的「停止生成」等按钮来判断状态；点击镜像切换播放；移动窗口 |
| 音频读取 | 只读取 iPhone 镜像的**音量数值**，判断视频是否在播放 |

## 隐私

- **不联网**：代码中没有任何网络请求，不上传任何数据。
- **不读聊天内容**：只识别按钮和控件状态，不读取对话正文。Hooks 桥接器会丢弃 prompt、回答、工具输入等内容，只保留状态。
- **不录音、不截图**：音频只取音量，不保存。
- 运行日志只保存在本机 `~/Library/Application Support/MoyuRelay/`，设置页的「卸载」会一并删除。

## 从源码构建

需要 Xcode Command Line Tools（Swift 6）。

```sh
bash scripts/build-app.sh            # 产物在 dist/Vibe Fishing.app
```

默认使用 ad-hoc 签名，每次重新构建后 macOS 可能要求重新授权。若有自己的签名证书：

```sh
RELAY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/build-app.sh
```

运行测试：

```sh
python3 scripts/test-core.py
python3 scripts/test-window-layout.py
python3 scripts/test-launch-flow.py
```

## 项目结构

```
Sources/
  RelayCore/     纯逻辑：状态机、播放信号融合、启动流程（有单元测试）
  MoyuRelay/     macOS App：界面、辅助功能探测、镜像控制、窗口排列
  relayctl/      命令行桥接器，把 Codex / Claude Code hooks 转为本地事件
scripts/         构建、hooks 配置生成、测试脚本
Tests/           单元测试与集成测试
docs/            Hooks 接入、快捷键说明
```

## 已知限制

- 状态识别依赖 AI 应用和 iPhone 镜像的界面结构，对方更新界面后可能需要适配。
- 自定义添加的 AI 应用没有专门校准，可能识别不到生成状态。
- 插拔显示器后需手动点小窗上的「重新排列窗口」。

## 参与贡献

欢迎提 Issue 和 PR，特别是：新 AI 应用的状态识别适配、新视频 App 的连播说明、界面变化导致的失效修复。

## 许可证

[GPL-3.0](LICENSE)。你可以自由使用、修改和分发；分发修改版时须同样以 GPL-3.0 开源。

## 声明

本项目为个人开源项目，与 Apple、OpenAI、Anthropic、Cursor 及任何视频平台无关联，也未获得其认可。文中提及的产品名称归各自所有者所有。
