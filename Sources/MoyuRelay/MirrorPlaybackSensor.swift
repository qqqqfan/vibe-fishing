import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import RelayCore

/// Reduces audio to numbers inside the IO callback. Samples are never stored.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var sumSquares = 0.0
    private var count = 0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func add(_ list: UnsafePointer<AudioBufferList>) {
        var squares = 0.0
        var samples = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.bindMemory(to: Float.self, capacity: total)
            for index in 0..<total { squares += Double(floats[index] * floats[index]) }
            samples += total
        }
        os_unfair_lock_lock(lock)
        sumSquares += squares
        count += samples
        os_unfair_lock_unlock(lock)
    }

    /// nil means no audio callback arrived since the previous drain.
    func drainLevelDB() -> Double? {
        os_unfair_lock_lock(lock)
        let squares = sumSquares
        let samples = count
        sumSquares = 0
        count = 0
        os_unfair_lock_unlock(lock)
        guard samples > 0 else { return nil }
        return squares > 0 ? 10 * log10(squares / Double(samples)) : -200
    }
}

/// macOS has no public preflight for system audio capture: a denied tap still
/// runs and delivers digital silence. Authorization is therefore proven by
/// evidence: the first real sound heard through the tap. The proof is kept
/// across launches so a video that is already paused at launch reads as paused,
/// and is withdrawn when repeated resume clicks produce no sound at all.
enum AudioCaptureVerification {
    private static let key = "audioCaptureVerified.v1"
    static var isVerified: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markVerified() {
        guard !isVerified else { return }
        UserDefaults.standard.set(true, forKey: key)
    }
    static func withdraw() { UserDefaults.standard.removeObject(forKey: key) }
}

private struct AudioTapError: Error {
    let stage: String
    let status: OSStatus
}

/// A private, non-muting tap of one process. The user keeps hearing the video.
@available(macOS 14.2, *)
private final class MirrorAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "moyu.relay.mirror-audio", qos: .userInteractive)

    init(pid: pid_t, outputUID: String, meter: AudioLevelMeter) throws {
        do {
            let process = try Self.processObject(pid)
            let description = CATapDescription(stereoMixdownOfProcesses: [process])
            description.uuid = UUID()
            description.name = "MoyuRelayMirrorTap"
            description.muteBehavior = .unmuted
            description.isPrivate = true
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "tap")
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MoyuRelayMirrorLevel",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "aggregate")
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, input, _, _, _ in
                meter.add(input)
            }, "ioproc")
            try Self.check(AudioDeviceStart(device, ioProc), "start")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if device != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private static func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw AudioTapError(stage: stage, status: status) }
    }

    private static func processObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var target = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &target, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            throw AudioTapError(stage: "process", status: status)
        }
        return object
    }
}

/// Always-on, pixel-free view of whether the mirrored video is playing. It never
/// takes a screenshot: a one-shot capture of the mirror surfaces on the phone as
/// a screenshot, and Douyin's reaction to that polluted every image comparison.
@MainActor
final class MirrorPlaybackSensor {
    typealias Reading = PlaybackSignalFusion.Reading

    private(set) var reading = Reading()
    private(set) var audioDiagnostics = "未启动"
    var onChange: ((Reading) -> Void)?
    /// How usable the phone's volume is as a detection signal.
    enum AudioHealth: Equatable { case unknown, good, low, none }
    private(set) var audioHealth: AudioHealth = .unknown
    var onAudioHealthChange: ((AudioHealth) -> Void)?
    private var soundLevels: [(time: TimeInterval, level: Double)] = []
    var isRunning: Bool { timer != nil }

    private var fusion = PlaybackSignalFusion()
    private var timer: DispatchSourceTimer?
    private var pid: pid_t?
    private var tapHandle: AnyObject?
    private var tapStop: (() -> Void)?
    private var meter = AudioLevelMeter()
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var lastOutputCheck: TimeInterval = 0
    private var lastTapStart: TimeInterval = 0
    private var lastAudioCallback: TimeInterval = 0
    private var streamPID: pid_t?
    private var lastStreamLookup: TimeInterval = 0
    private var lastStreamCPU: UInt64?
    private var lastStreamTime: TimeInterval = 0
    private var latestLevel: Double?
    private var latestLoad: Double?
    private var timebaseScale = 1.0

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseScale = Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    func start(pid: pid_t) {
        guard self.pid != pid || timer == nil else { return }
        stop()
        self.pid = pid
        startTap()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(15))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = source
        source.resume()
    }

    /// Called when resume clicks repeatedly produce no sound: the stored proof
    /// may be stale (permission revoked), so stop trusting silence.
    /// No audible sample in the latest reading.
    var latestLevelIsSilent: Bool { (latestLevel ?? -200) < -70 }

    func withdrawAudioTrust() {
        AudioCaptureVerification.withdraw()
        fusion.audioTrusted = false
        audioDiagnostics = "已连接（等待首次声音）"
    }

    func stop() {
        timer?.cancel()
        timer = nil
        stopTap()
        pid = nil
        fusion.reset()
        reading = fusion.reading
        latestLevel = nil
        latestLoad = nil
        lastStreamCPU = nil
        audioDiagnostics = "未启动"
        soundLevels = []
        updateAudioHealth(.unknown)
    }

    /// Returns once the signals agree on a state, or the latest reading at the
    /// deadline. A cancelled wait returns immediately and is never acted on.
    func settled(timeout: TimeInterval) async -> Reading {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if reading.state != .unknown, !reading.settling { return reading }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return reading
    }

    /// Waits for `target` based on evidence newer than `after`.
    func wait(for target: MirrorPlaybackState, after: TimeInterval, timeout: TimeInterval) async -> Reading {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if reading.state == target, !reading.settling, reading.changedAt >= after { return reading }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return reading
    }

    var summary: [String: String] {
        ["state": reading.state.rawValue, "settling": String(reading.settling), "strong": String(reading.strong),
         "reason": reading.reason.rawValue, "audioProven": String(fusion.audioProven),
         "levelDB": latestLevel.map { String(format: "%.1f", $0) } ?? "none",
         "streamLoad": fusion.smoothedLoad.map { String(format: "%.0f", $0) } ?? "none",
         "audio": audioDiagnostics]
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let level = meter.drainLevelDB()
        if level != nil { lastAudioCallback = now }
        latestLevel = level
        latestLoad = readStreamLoad(now)
        maintainTap(now)
        let changed = fusion.ingest(PlaybackSignalSample(time: now, audioLevelDB: level, streamLoad: latestLoad))
        if fusion.audioProven, !fusion.audioTrusted {
            AudioCaptureVerification.markVerified()
            fusion.audioTrusted = true
            audioDiagnostics = "已连接"
        }
        if changed {
            reading = fusion.reading
            onChange?(reading)
        }
        assessAudioHealth(now: now, level: level)
    }

    /// Judged on the loudest moment of the last 8 seconds of sound, so a quiet
    /// line does not flag the volume as low. Measured 2026-11-05: at the phone's
    /// lowest step the loudest moment per second was about -30 to -40 dB, against
    /// -15 to -25 dB normally, so only a nearly silent phone is flagged.
    private func assessAudioHealth(now: TimeInterval, level: Double?) {
        if let level, level >= -70 { soundLevels.append((now, level)) }
        soundLevels.removeAll { now - $0.time > 8 }
        if let loudest = soundLevels.map(\.level).max() {
            updateAudioHealth(soundLevels.count >= 10 ? (loudest < -40 ? .low : .good) : audioHealth)
        } else if reading.state == .playing, !reading.settling,
                  reading.reason == .silentVideo || reading.reason == .streamMoving,
                  now - reading.changedAt >= 5 {
            updateAudioHealth(.none)
        }
    }

    private func updateAudioHealth(_ next: AudioHealth) {
        guard next != audioHealth else { return }
        audioHealth = next
        onAudioHealthChange?(next)
    }

    /// CPU of the daemon that receives and decodes the mirror stream. A still
    /// phone screen sends almost nothing, so this tracks video without pixels.
    private func readStreamLoad(_ now: TimeInterval) -> Double? {
        if streamPID == nil, now - lastStreamLookup >= 5 {
            lastStreamLookup = now
            streamPID = Self.pid(named: "avconferenced")
            lastStreamCPU = nil
        }
        guard let streamPID else { return nil }
        guard let cpu = Self.cpuTime(streamPID) else {
            self.streamPID = nil
            lastStreamCPU = nil
            return nil
        }
        defer { lastStreamCPU = cpu; lastStreamTime = now }
        guard let previous = lastStreamCPU, now > lastStreamTime else { return latestLoad }
        return Double(cpu &- previous) * timebaseScale / (now - lastStreamTime)
    }

    /// Rebuild when the output device changes or callbacks stop arriving.
    private func maintainTap(_ now: TimeInterval) {
        guard now - lastOutputCheck >= 1 else { return }
        lastOutputCheck = now
        let device = Self.defaultOutputDevice()
        let outputChanged = device != outputDevice && device != kAudioObjectUnknown
        let stalled = now - lastAudioCallback > 2.5
        guard outputChanged || stalled, now - lastTapStart >= 3 else { return }
        stopTap()
        startTap()
    }

    private func startTap() {
        guard let pid else { return }
        lastTapStart = ProcessInfo.processInfo.systemUptime
        lastAudioCallback = lastTapStart
        guard #available(macOS 14.2, *) else {
            audioDiagnostics = "需要 macOS 14.2，仅使用画面流信号"
            return
        }
        outputDevice = Self.defaultOutputDevice()
        guard let outputUID = Self.deviceUID(outputDevice) else {
            audioDiagnostics = "没有可用的音频输出设备"
            return
        }
        do {
            let audioTap = try MirrorAudioTap(pid: pid, outputUID: outputUID, meter: meter)
            tapHandle = audioTap
            tapStop = { audioTap.stop() }
            fusion.audioTrusted = AudioCaptureVerification.isVerified
            audioDiagnostics = fusion.audioTrusted ? "已连接" : "已连接（等待首次声音）"
        } catch let error as AudioTapError {
            audioDiagnostics = "音频未连接：\(error.stage)=\(error.status)"
        } catch {
            audioDiagnostics = "音频未连接"
        }
    }

    private func stopTap() {
        tapStop?()
        tapStop = nil
        tapHandle = nil
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_user_time + info.ri_system_time : nil
    }

    private static func pid(named name: String) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 8192)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return nil }
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &buffer, 256) > 0, String(cString: buffer) == name { return pid }
        }
        return nil
    }
}
