import AppKit
import SwiftUI
import RelayCore

// Resolve the property wrapper explicitly; the latest SDK also exports a
// same-named macro whose plugin is not shipped in Command Line Tools.
private typealias RelayViewState<Value> = SwiftUI.State<Value>

/// Kept for call sites that predate the brand tokens.
let relayTeal = VFTheme.accent

struct RelayMainView: View {
    @ObservedObject var store: RelayStore
    @RelayViewState private var settingsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VFFishMark().foregroundStyle(VFTheme.accent).frame(width: 18, height: 18)
                Text("Vibe Fishing")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(VFTheme.ink)
                Spacer()
                Button { settingsPresented = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VFTheme.ink)
                        .frame(width: 30, height: 30)
                        .background(VFTheme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(VFTheme.line, lineWidth: 1))
                }.buttonStyle(.plain)
                    .accessibilityLabel("设置")
                    .help("设置")
            }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                LaunchHomeView(store: store)
                    .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 22)
            }
        }
        .foregroundStyle(VFTheme.ink)
        .background(VFTheme.canvas)
        .tint(VFTheme.accent)
        .frame(minWidth: 420, minHeight: 600)
        .sheet(isPresented: $settingsPresented) {
            RelaySettingsView(store: store)
        }
    }
}

struct RelaySettingsView: View {
    @ObservedObject var store: RelayStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(VFSmallButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            Rectangle().fill(VFTheme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsSection("权限", symbol: "hand.raised") {
                        RelaySwitchRow(title: "辅助功能", isOn: Binding(
                            get: { store.permissions.accessibilityGranted },
                            set: { store.permissions.setAccessibilityRequested($0) }
                        ))
                        rowDivider
                        RelaySwitchRow(title: "音频读取", isOn: Binding(
                            get: { store.permissions.audioCaptureGranted },
                            set: { _ in store.permissions.openAudioCaptureSettings() }
                        ))
                        footnote("通过镜像中的媒体音频信号判断播放状态。完全无声的视频可能无法在 AI 完成时自动暂停。")
                    }
                    settingsSection("快捷键", symbol: "keyboard") {
                        PlaybackShortcutRecorder(mirror: store.mirror)
                    }
                    settingsSection("提醒", symbol: "bell") {
                        RelaySwitchRow(title: "AI 窗口轮廓", isOn: $store.strongReminder)
                        rowDivider
                        RelaySwitchRow(title: "提示音", isOn: $store.soundReminder)
                            .disabled(!store.strongReminder)
                    }
                    settingsSection("窗口", symbol: "rectangle.split.2x1") {
                        RelaySwitchRow(title: "自动并排", isOn: Binding(
                            get: { store.launch.autoArrangeWindows },
                            set: { store.launch.autoArrangeWindows = $0 }
                        ))
                        Button("重新并排") {
                            store.refreshWindows()
                            store.launch.rearrange()
                        }.buttonStyle(VFSmallButtonStyle())
                    }
                    settingsSection("自定义应用", symbol: "square.grid.2x2") {
                        let custom = store.agentMonitor.customClients
                        ForEach(custom, id: \.bundleID) { client in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile:
                                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: client.bundleID)?.path ?? ""))
                                    .resizable().frame(width: 18, height: 18)
                                Text(client.name).font(.system(size: 13))
                                Spacer()
                                Button("移除") { store.removeCustomClient(bundleID: client.bundleID) }
                                    .buttonStyle(VFSmallButtonStyle())
                            }
                        }
                        Button("添加应用…") { store.addCustomClient() }.buttonStyle(VFSmallButtonStyle())
                        footnote("自定义应用参与窗口排列与生成检测；按钮词表未校准时可能识别不到生成状态。")
                    }
                    if store.hooks.statuses.values.contains(where: { $0 != .notDetected }) {
                        settingsSection("命令行工具", symbol: "terminal") {
                            ForEach(HookInstaller.Agent.allCases.filter { store.hooks.statuses[$0] != .notDetected }) { agent in
                                HStack {
                                    Text(agent.displayName).font(.system(size: 13))
                                    Spacer()
                                    if store.hooks.statuses[agent] == .installed {
                                        Button("移除") { store.hooks.uninstall(agent) }.buttonStyle(VFSmallButtonStyle())
                                    } else {
                                        Button(store.hooks.statuses[agent] == .broken ? "修复" : "接入") { store.hooks.install(agent) }
                                            .buttonStyle(VFSmallButtonStyle())
                                    }
                                }
                            }
                            if !store.hooks.message.isEmpty { footnote(store.hooks.message) }
                        }
                    }
                    HStack {
                        Button("导出诊断") { store.exportDiagnostics() }.buttonStyle(VFQuietButtonStyle())
                        Spacer()
                        Button("卸载…") { store.uninstallEverything() }.buttonStyle(VFQuietButtonStyle())
                    }.padding(.horizontal, 4).padding(.top, 4)
                }.padding(20)
            }
        }
        .foregroundStyle(VFTheme.ink)
        .background(VFTheme.canvas)
        .frame(width: 440, height: 520).tint(VFTheme.accent)
        .onAppear { store.permissions.refresh() }
    }

    private var rowDivider: some View {
        Rectangle().fill(VFTheme.line).frame(height: 1)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(VFTheme.muted)
            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VFTheme.accent)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(VFTheme.muted)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfCardSurface(cornerRadius: 14)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keep the switch on the trailing edge in both settings and guided steps.
struct RelaySwitchRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(VFTheme.ink)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .tint(VFTheme.accent)
                .accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Optional companion remains a status surface, never a second setup flow.
struct RelayUsageInstructions: View {
    @ObservedObject var mirror: MirrorController
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("让你在AI工具（如ChatGPT、Claude、Cursor）处理任务时尽情摸鱼，通过Macbook自带的iPhone镜像自动连播手机中的竖屏短视频（如抖音、小红书、bilibili、红果短剧等）；")
            Text("AI完成当前任务时自动暂停视频、提醒你返回工作；AI开始处理工作时，短视频自动复播让你继续摸鱼。")
            Text(mirror.shortcutLabel == "未设置" ? "可在设置中录入快捷键，手动暂停/播放视频" : "按下快捷键\(mirror.shortcutLabel)（可在设置中设置）可手动暂停/播放视频")
                .foregroundStyle(VFTheme.muted)
        }.font(.system(size: 13)).lineSpacing(3)
            .foregroundStyle(VFTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PlaybackShortcutHint: View {
    @ObservedObject var mirror: MirrorController
    var body: some View {
        Text(mirror.shortcutLabel == "未设置" ? "快捷键未设置" : "按 \(mirror.shortcutLabel) 手动播放/暂停视频")
            .lineLimit(1)
            .help("快捷键可在详情的设置页中更改")
    }
}

struct PlaybackShortcutRecorder: View {
    @ObservedObject var mirror: MirrorController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("播放 / 暂停").font(.system(size: 13))
                Spacer()
                Button(mirror.recordingShortcut ? "请按快捷键…" : mirror.shortcutLabel) {
                    mirror.recordingShortcut.toggle()
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(mirror.recordingShortcut ? Color.white : VFTheme.ink)
                .padding(.horizontal, 12).frame(minHeight: 26)
                .background(mirror.recordingShortcut ? VFTheme.accent : VFTheme.lilac,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(VFTheme.outline.opacity(0.55), lineWidth: 1))
                .buttonStyle(.plain)
                Button("恢复 Fn") { mirror.restorePlaybackShortcut() }.buttonStyle(VFSmallButtonStyle())
            }
            Text(mirror.recordingShortcut ? "按 Fn 或组合键（如 ⌃⌥Space）。Esc 取消，Delete 清除。" : "点击右侧快捷键后录入；连接后按一次切换视频播放 / 暂停。")
                .font(.system(size: 11)).foregroundStyle(VFTheme.muted)
            Text("组合键须包含 ⌘、⌃ 或 ⌥。请避开系统及 AI 应用快捷键；Fn 可能同时触发系统功能。")
                .font(.system(size: 11)).foregroundStyle(VFTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.onDisappear { mirror.recordingShortcut = false }
    }
}

struct CompanionView: View {
    @ObservedObject var store: RelayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: the two states that matter, nothing else.
            HStack(spacing: 8) {
                Circle().fill(store.launch.isStarted ? VFTheme.accent : VFTheme.outline.opacity(0.45))
                    .frame(width: 6, height: 6)
                    .help(store.launch.isStarted ? "AI 工具与 iPhone 镜像已连接" : store.launch.detail)
                Menu {
                    ForEach(store.windows) { window in
                        Button(window.appName + (window.title.isEmpty ? "" : " · " + window.title)) {
                            store.switchRelayWindow(window.id)
                        }
                    }
                } label: {
                    Text(store.selectedWindow?.appName ?? "AI 工具")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize()
                    .help("切换关联的 AI 工具窗口")
                Text(aiStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.state == .running ? VFTheme.accent : VFTheme.ink)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: videoIsPlaying ? "play.fill" : "pause.fill").font(.system(size: 8))
                    Text("视频" + videoStatusText)
                }.font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(videoIsPlaying ? VFTheme.accent : VFTheme.muted)
                    .help(store.mirror.shortcutLabel == "未设置" ? "快捷键未设置" : "按 \(store.mirror.shortcutLabel) 手动播放 / 暂停")
            }
            // Row 2: quiet stats on the left, icon-only actions on the right.
            HStack(spacing: 6) {
                Text(store.launch.isStarted ? store.companionStatsLine : store.launch.detail)
                    .font(.system(size: 10)).foregroundStyle(VFTheme.muted)
                    .lineLimit(1).padding(.leading, 14)
                Spacer(minLength: 6)
                iconButton("rectangle.split.2x1", help: "重新排列窗口") { store.launch.rearrangeLayout() }
                    .disabled(!store.launch.isStarted)
                iconButton("ellipsis", help: "详情与设置") { store.onShowDetails?() }
            }
        }.padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity)
            .background(VFTheme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(VFTheme.line).frame(height: 1) }
            .tint(VFTheme.accent)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(VFTheme.muted)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private var aiStatusText: String {
        switch store.state {
        case .running: return "思考中"
        case .completed: return "等待响应"
        case .needsInput: return "等待确认"
        case .failed: return "出错"
        case .cancelled: return "已取消"
        default: return "等待响应"
        }
    }

    private var videoStatusText: String {
        guard store.launch.isStarted else { return "未连接" }
        if store.mirror.stateLabel.contains("播放") { return "播放中" }
        if store.mirror.stateLabel.contains("暂停") { return "暂停" }
        return store.mirror.stateLabel
    }

    private var videoIsPlaying: Bool {
        store.launch.isStarted && store.mirror.stateLabel.contains("播放")
    }
}
