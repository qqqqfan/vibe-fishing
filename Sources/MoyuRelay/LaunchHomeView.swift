import AppKit
import SwiftUI
import RelayCore

struct LaunchHomeView: View {
    @ObservedObject var store: RelayStore

    private var active: Bool {
        store.launch.flow.status != .idle && store.launch.flow.status != .cancelled
    }
    private var connected: Bool { store.listening && store.launch.isStarted }
    private var isLocal: Bool { store.playback.kind == .local }
    private var currentStep: LaunchStep? { store.launch.flow.currentStep }
    private var automaticSetup: Bool {
        !isLocal && (currentStep == .connectPlayback || currentStep == .startListening)
    }
    private var visibleSteps: [LaunchStep] {
        store.launch.steps.filter { $0 != .startListening && (isLocal || $0 != .connectPlayback) }
    }
    private var visibleIndex: Int {
        currentStep.flatMap { visibleSteps.firstIndex(of: $0) } ?? max(0, visibleSteps.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !active { welcome }
            else if connected { dashboard }
            else { setup }
        }.frame(maxWidth: .infinity).foregroundStyle(VFTheme.ink)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            HStack {
                VFStatusPill(text: "未连接")
                Spacer()
                Text("Mac + iPhone").font(.system(size: 11)).foregroundStyle(VFTheme.muted)
            }
            RelayScene().padding(.top, 4)
            VStack(spacing: 9) {
                Text("vibe coding 间隙摸鱼助手")
                    .font(.system(size: 27, weight: .bold, design: .rounded)).tracking(-0.6).lineSpacing(4)
                    .multilineTextAlignment(.center)
                Text("在 AI 工作时爽刷短剧 / 视频")
                    .font(.system(size: 13)).foregroundStyle(VFTheme.muted)
            }.padding(.top, 4)
            VStack(spacing: 0) {
                requirementRow(symbol: "laptopcomputer.and.iphone",
                               title: "仅支持 macOS + iPhone 镜像",
                               detail: "macOS 15 / iOS 18 及以上，同一 Apple 账户并开启双重认证；两台设备在附近，开启 Wi-Fi 和蓝牙，连接时将 iPhone 锁屏。")
                Rectangle().fill(VFTheme.line).frame(height: 1).padding(.leading, 44)
                requirementRow(symbol: "sparkles",
                               title: "支持 ChatGPT、Claude、Cursor",
                               detail: "可在设置中添加其他应用或接入命令行工具。")
            }.padding(.horizontal, 14).vfCardSurface(cornerRadius: 16).padding(.top, 22)
            Button { store.launch.startOrRetry() } label: {
                HStack {
                    Spacer()
                    Text("开始连接")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
            }.buttonStyle(VFPrimaryButtonStyle()).padding(.top, 18)
                .accessibilityLabel("开始连接 Vibe Fishing")
            DisclosureGroup {
                RelayUsageInstructions(mirror: store.mirror).padding(.top, 10)
            } label: {
                Text("工作方式").font(.system(size: 11)).foregroundStyle(VFTheme.muted)
            }.padding(.top, 20)
        }
    }

    private func requirementRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(VFTheme.accent)
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).lineSpacing(2).foregroundStyle(VFTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(automaticSetup ? "正在完成连接" : "连接设置")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(VFTheme.muted)
                    Spacer()
                    Text("\(visibleIndex + 1) / \(visibleSteps.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(VFTheme.muted)
                }
                HStack(alignment: .top, spacing: 5) {
                    ForEach(Array(visibleSteps.enumerated()), id: \.element.rawValue) { index, step in
                        VStack(spacing: 4) {
                            Capsule().fill(index <= visibleIndex ? VFTheme.accent : VFTheme.lilac)
                                .frame(height: 5)
                                .overlay(Capsule().stroke(VFTheme.outline.opacity(0.30), lineWidth: 0.75))
                            Text(stepShortLabel(step))
                                .font(.system(size: 9.5, weight: index == visibleIndex ? .semibold : .regular))
                                .foregroundStyle(index == visibleIndex ? VFTheme.accent : VFTheme.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .help("第 \(index + 1) 步 · \(stepHint(step))")
                        .accessibilityLabel("第 \(index + 1) 步 \(stepHint(step))，\(index < visibleIndex ? "已完成" : index == visibleIndex ? "当前步骤" : "待完成")")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                VFSymbolTile(symbol: stepSymbol, size: 52)
                Text(stepTitle).font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-0.5)
                Text(stepDescription).font(.system(size: 13)).lineSpacing(4)
                    .foregroundStyle(VFTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !automaticSetup { stepContent }
            if store.launch.isBusy {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在检查，请稍候…").font(.system(size: 12)).foregroundStyle(VFTheme.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 13)
            } else {
                Button { store.launch.advanceCurrentStep() } label: {
                    HStack {
                        Spacer()
                        Text(primaryTitle)
                        Spacer()
                        Image(systemName: currentStep == .grantPermissions && !store.permissions.accessibilitySettingsOpened && !store.permissions.accessibilityGranted ? "arrow.up.right" : "arrow.right")
                    }
                }.buttonStyle(VFPrimaryButtonStyle())
            }
            Button("取消连接") { store.launch.stop() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(VFTheme.muted)
                .frame(maxWidth: .infinity)
        }
    }

    private var stepSymbol: String {
        switch currentStep {
        case .grantPermissions: return "hand.raised"
        case .openAIClient: return "macwindow"
        case .openPhoneMirror: return "iphone.gen3.radiowaves.left.and.right"
        case .openPreferredPhoneApp: return "play.rectangle"
        case .arrangeWindows: return "rectangle.split.2x1"
        case .connectPlayback: return isLocal ? "film" : "link"
        default: return "link"
        }
    }
    /// One-line purpose of each setup step, shown on hover.
    private func stepHint(_ step: LaunchStep) -> String {
        switch step {
        case .grantPermissions: return "macOS 授权"
        case .openAIClient: return "打开支持的 AI 工具"
        case .openPhoneMirror: return "打开 iPhone 镜像"
        case .openPreferredPhoneApp: return "在镜像里打开想刷的短视频/短剧 App"
        case .arrangeWindows: return "一键整理窗口开始工作/摸鱼"
        default: return store.launch.stepTitle(step)
        }
    }

    /// Compact label under each progress segment.
    private func stepShortLabel(_ step: LaunchStep) -> String {
        switch step {
        case .grantPermissions: return "macOS 授权"
        case .openAIClient: return "打开 AI 工具"
        case .openPhoneMirror: return "iPhone 镜像"
        case .openPreferredPhoneApp: return "打开短视频"
        case .arrangeWindows: return "整理窗口"
        default: return ""
        }
    }

    private var stepTitle: String {
        if automaticSetup { return store.launch.isBusy ? "连接即将就绪" : "继续完成连接" }
        switch currentStep {
        case .grantPermissions: return "允许接力控制"
        case .openAIClient: return "打开你的 AI 应用"
        case .openPhoneMirror: return "连接 iPhone 镜像"
        case .openPreferredPhoneApp: return "打开想看的视频"
        case .arrangeWindows: return "让两个窗口并排"
        case .connectPlayback: return "选择本地视频"
        default: return "准备连接"
        }
    }
    private var stepDescription: String {
        switch currentStep {
        case .grantPermissions:
            if !LaunchCoordinator.meetsSystemRequirements { return store.launch.detail }
            return "在系统设置中开启所需权限，返回后会自动检查。"
        case .openAIClient:
            return "选择要使用的 AI 应用。已打开的会唤起窗口，未打开的会直接启动。"
        case .openPhoneMirror:
            return store.launch.isBusy ? "正在打开 iPhone 镜像。将 iPhone 锁屏，并放在 Mac 附近。" : store.launch.detail
        case .openPreferredPhoneApp:
            return "在镜像中打开抖音、红果等 App，进入竖屏视频页。"
        case .arrangeWindows:
            return store.launch.isBusy ? "正在把 AI 应用和镜像排列到同一屏幕。" : store.launch.detail
        case .connectPlayback where isLocal:
            return "选择一部或多集视频，按顺序播放。"
        default:
            return store.launch.isBusy ? "正在连接任务状态与视频控制。" : store.launch.detail
        }
    }
    private var primaryTitle: String {
        if automaticSetup { return "重试连接" }
        switch currentStep {
        case .grantPermissions:
            if store.permissions.accessibilityGranted { return "继续" }
            return store.permissions.accessibilitySettingsOpened ? "重新检查权限" : "打开系统设置"
        case .openAIClient: return "重新检查"
        case .openPhoneMirror: return "我已连接镜像"
        case .openPreferredPhoneApp: return "已进入视频页，开始接力"
        case .arrangeWindows: return "重新排列"
        default: return store.launch.primaryActionTitle
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        if currentStep == .grantPermissions {
            VStack(spacing: 0) {
                permissionRow(symbol: "cursorarrow.motionlines", title: "辅助功能",
                              detail: "排列窗口、识别 AI 状态与控制播放。",
                              status: store.permissions.accessibilityGranted ? "已授权" : "需开启",
                              verified: store.permissions.accessibilityGranted,
                              binding: Binding(get: { store.permissions.accessibilityGranted },
                                               set: { store.permissions.setAccessibilityRequested($0) }))
                if !isLocal {
                    Rectangle().fill(VFTheme.line).frame(height: 1).padding(.leading, 48)
                    permissionRow(symbol: "waveform", title: "音频读取",
                                  detail: "判断镜像是否播放，不录音、不保存。",
                                  status: store.permissions.audioCaptureGranted ? "已验证" : "待验证",
                                  verified: store.permissions.audioCaptureGranted,
                                  binding: Binding(get: { store.permissions.audioCaptureGranted },
                                                   set: { _ in store.permissions.openAudioCaptureSettings() }))
                }
            }.padding(.horizontal, 15).vfCardSurface(cornerRadius: 16)
            if !isLocal && !store.permissions.audioCaptureGranted {
                Text("音频权限会在视频播放后验证；“待验证”不代表未授权。点击开关可前往系统设置管理。")
                    .font(.system(size: 11)).lineSpacing(3).foregroundStyle(VFTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.permissions.accessibilitySettingsOpened && !store.permissions.accessibilityGranted {
                DisclosureGroup("已开启权限，仍无法继续？") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("若列表中是旧版应用，移除旧条目，再用“＋”添加当前版本。")
                        HStack {
                            Button("打开权限设置") { store.permissions.openAccessibilitySettings() }
                            Button("显示当前应用") { store.permissions.revealCurrentApplication() }
                        }.controlSize(.small)
                    }.font(.system(size: 12)).foregroundStyle(VFTheme.muted).padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
        if currentStep == .openAIClient && store.launch.flow.status == .blocked {
            VStack(spacing: 8) {
                let clients = store.launch.installableClients
                if clients.isEmpty {
                    Text("未找到已安装的 AI 应用。可添加其他应用。")
                        .font(.system(size: 12)).foregroundStyle(VFTheme.muted)
                }
                ForEach(clients, id: \.bundleID) { client in
                    let opening = store.launch.openingClientID == client.bundleID
                    Button { store.launch.chooseClient(bundleID: client.bundleID) } label: {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: client.url.path))
                                .resizable().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(client.name).font(.system(size: 13, weight: .semibold))
                                Text(opening ? "正在打开窗口…" : client.running ? "已运行 · 点击唤起窗口" : "未运行 · 点击打开")
                                    .font(.system(size: 11)).foregroundStyle(VFTheme.muted)
                            }
                            Spacer()
                            if opening {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12)).foregroundStyle(VFTheme.accent)
                            }
                        }.padding(13).vfCardSurface(cornerRadius: 13)
                    }.buttonStyle(.plain)
                        .disabled(store.launch.openingClientID != nil)
                }
                HStack {
                    Button("添加其他应用…") { store.addCustomClient() }
                    Spacer()
                }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(VFTheme.accent).padding(.top, 5)
            }
        }
        if currentStep == .openPhoneMirror {
            VStack(alignment: .leading, spacing: 16) {
                preparationRow("1", title: "锁定 iPhone", detail: "重启后先解锁一次，再锁屏连接。", symbol: "lock.iphone")
                preparationRow("2", title: "在镜像窗口完成连接", detail: "如出现 Touch ID 提示，请在 Mac 上验证。", symbol: "touchid")
            }.padding(17).vfCardSurface(cornerRadius: 16)
            DisclosureGroup("连接条件与排查") {
                Text("Mac 需为 Apple 芯片或 T2 芯片，macOS 15 及以上；iPhone 需为 iOS 18 及以上。登录同一 Apple 账户并开启双重认证，两台设备开启 Wi-Fi、蓝牙并保持在附近。")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(VFTheme.muted).padding(.top, 8)
            }.font(.system(size: 12))
        }
        if currentStep == .openPreferredPhoneApp {
            VStack(alignment: .leading, spacing: 16) {
                preparationRow("1", title: "进入竖屏视频页", detail: "打开一条视频，先确认能正常播放。", symbol: "play.rectangle")
                preparationRow("2", title: "开启自动连播", detail: "避免一条播完后停住。", symbol: "repeat")
            }.padding(17).vfCardSurface(cornerRadius: 16)
            DisclosureGroup("在哪里开启自动连播？") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("抖音 / 小红书：播放视频时长按屏幕，在屏幕下方弹出的菜单中开启“自动连播”。")
                    Text("红果 / 哔哩哔哩：播放时点右上角「…」，在弹出的菜单中开启“自动连播”。")
                    Text("入口可能随版本变化，也可在 App 设置内搜索“连播”。")
                }.font(.system(size: 12)).lineSpacing(3).foregroundStyle(VFTheme.muted).padding(.top, 8)
            }.font(.system(size: 12))
            VFNotice(text: "播放状态由媒体音频信号判断，完全无声的视频可能无法自动暂停。", symbol: "waveform")
        }
        if currentStep == .connectPlayback && isLocal && !store.playback.videoNames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("已选择 \(store.playback.videoNames.count) 个视频", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(VFTheme.accent)
                Text(store.playback.videoNames.first ?? "").font(.system(size: 12)).foregroundStyle(VFTheme.muted).lineLimit(1)
                Button("更换视频") { store.playback.chooseVideos() }.controlSize(.small)
            }
        }
    }

    private func permissionRow(symbol: String, title: String, detail: String, status: String, verified: Bool, binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(VFTheme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(status).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(verified ? VFTheme.accent : VFTheme.muted)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(VFTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("\(title)，\(status)，在系统设置管理")
        }.padding(.vertical, 17)
    }

    private func preparationRow(_ number: String, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 22).background(VFTheme.lilac, in: Circle())
                .overlay(Circle().stroke(VFTheme.outline.opacity(0.45), lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(VFTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(VFTheme.accent).frame(width: 24)
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VFStatusPill(text: "已连接", active: true)
                Spacer()
                Text("自动接力已开启").font(.system(size: 11)).foregroundStyle(VFTheme.muted)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.state == .idle ? "等待 AI 开始" : store.state.displayName)
                        .font(.system(size: 28, weight: .bold, design: .rounded)).tracking(-0.5)
                    Text(dashboardDescription).font(.system(size: 13)).lineSpacing(3).foregroundStyle(VFTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                statusRow(symbol: "macwindow", name: store.selectedWindow?.appName ?? "AI 应用",
                          value: store.state == .idle ? "待命" : store.state.displayName,
                          active: store.state == .running)
                Rectangle().fill(VFTheme.line).frame(height: 1).padding(.leading, 52)
                statusRow(symbol: isLocal ? "film" : "iphone", name: isLocal ? "本地视频" : "iPhone 镜像",
                          value: isLocal ? store.playback.observedStateCaption : store.mirror.stateLabel,
                          active: !isLocal && store.mirror.stateLabel.contains("播放"))
            }.padding(.horizontal, 18).vfCardSurface(cornerRadius: 18)
            if isLocal {
                NativeVideoView(player: store.playback.player).frame(height: 150).background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if store.mirror.audioHealth == .low {
                    VFNotice(text: "媒体音频信号较弱，播放状态判断可能不准确。", symbol: "speaker.wave.1", warning: true)
                } else if store.mirror.audioHealth == .none {
                    VFNotice(text: "未检测到媒体音频信号，完全无声的视频可能无法自动暂停。", symbol: "speaker.slash", warning: true)
                }
                if !store.mirror.message.isEmpty {
                    Text(store.mirror.message).font(.system(size: 12)).lineSpacing(3).foregroundStyle(VFTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("本次连接").font(.system(size: 10, weight: .medium)).foregroundStyle(VFTheme.muted)
                    Text(store.companionStatsLine).font(.system(size: 12, weight: .medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("手动播放 / 暂停").font(.system(size: 10)).foregroundStyle(VFTheme.muted)
                    Text(store.mirror.shortcutLabel).font(.system(size: 12, weight: .medium, design: .monospaced))
                }
            }.padding(.vertical, 3)
            Button { store.onHideDetails?() } label: {
                HStack {
                    Spacer()
                    Text("回到小浮窗")
                    Spacer()
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
            }.buttonStyle(VFPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .help("关闭详情，状态条回到镜像上方")
            HStack(spacing: 12) {
                Button { store.launch.rearrangeLayout() } label: {
                    Label("重新排列窗口", systemImage: "rectangle.split.2x1")
                }.buttonStyle(VFSecondaryButtonStyle())
                Button("断开连接") { store.launch.stop() }.buttonStyle(VFSecondaryButtonStyle())
            }
        }
    }
    private var dashboardDescription: String {
        if store.state == .idle { return "AI 开始思考时视频自动播放。" }
        switch store.state {
        case .running: return "任务进行中，视频会自动续播。"
        case .completed: return "本轮任务已完成，可以回到 AI 应用。"
        case .needsInput: return "AI 正在等待你的确认。"
        case .failed: return "任务出现问题，请回到 AI 应用查看。"
        case .cancelled: return "任务已取消，等待下一次生成。"
        default: return "下一次生成开始时，视频会自动续播。"
        }
    }
    private func statusRow(symbol: String, name: String, value: String, active: Bool) -> some View {
        HStack(spacing: 13) {
            VFSymbolTile(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 12)).foregroundStyle(VFTheme.muted).lineLimit(1)
                Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            }
            Spacer(minLength: 4)
            Circle().fill(active ? VFTheme.accent : VFTheme.line).frame(width: 7, height: 7)
        }.padding(.vertical, 20)
    }
}
