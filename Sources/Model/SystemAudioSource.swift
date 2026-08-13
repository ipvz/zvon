import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

/// Captures SYSTEM audio (everyone else on the call, through the speakers) via a Core Audio
/// process tap (`AudioHardwareCreateProcessTap`, macOS 14.2+). This uses the "System Audio
/// Recording" permission — NOT Screen Recording — so it doesn't trip the scary screen-record
/// prompt, and the grant is stable. Converts to 16 kHz mono and exposes the `LiveAudioSource`
/// window contract, so it plugs into `UtteranceTranscriber` exactly like the mic.
@available(macOS 14.2, *)
final class SystemAudioSource: LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float] = []
    private var frontOffset = 0

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let ioQueue = DispatchQueue(label: "com.parley.systemtap.io", qos: .userInitiated)
    /// Optional tap for archiving the audio — the same 16 kHz mono the transcriber sees, taken
    /// before any VAD windowing so the recording has no gaps.
    var onSamples: (@Sendable ([Float]) -> Void)?

    func start() throws {
        // 1. Global system-output tap, excluding nothing (mono-mixed later).
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr, tap != .unknown else {
            throw NSError(domain: "Parley.SystemAudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Не удалось создать аудио-тап (\(err)). Нужно разрешение «Запись системного звука»."])
        }
        tapID = tap

        // 2. Aggregate device wrapping the tap + the default output device.
        let outputUID = Self.defaultOutputDeviceUID()
        let aggUID = UUID().uuidString
        var subDevices: [[String: Any]] = []
        if let outputUID { subDevices = [[kAudioSubDeviceUIDKey as String: outputUID]] }
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Parley-SystemTap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: desc.uuid.uuidString,
            ]],
        ]
        if let outputUID { description[kAudioAggregateDeviceMainSubDeviceKey as String] = outputUID }

        var agg: AudioObjectID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard err == noErr, agg != .unknown else {
            AudioHardwareDestroyProcessTap(tapID); tapID = .unknown
            throw NSError(domain: "Parley.SystemAudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Не удалось создать aggregate-устройство (\(err))."])
        }
        aggregateID = agg

        // 3. Tap stream format (usually Float32 stereo @ device rate).
        if var asbd = Self.tapStreamFormat(tapID) {
            tapFormat = AVAudioFormat(streamDescription: &asbd)
        }

        // 4. IOProc → convert → ring.
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard err == noErr, let proc else {
            teardown()
            throw NSError(domain: "Parley.SystemAudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Не удалось создать IOProc (\(err))."])
        }
        ioProcID = proc
        err = AudioDeviceStart(aggregateID, proc)
        guard err == noErr else {
            teardown()
            throw NSError(domain: "Parley.SystemAudio", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить захват (\(err))."])
        }
        DebugLog.log("SystemAudio tap started (fmt=\(tapFormat?.description ?? "?"))")
    }

    func stop() { teardown() }

    private func teardown() {
        if let ioProcID, aggregateID != .unknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != .unknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = .unknown }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID); tapID = .unknown }
    }

    // MARK: - LiveAudioSource window

    func snapshotSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard frontOffset < ring.count else { return [] }
        return Array(ring[frontOffset...])
    }

    func snapshotEnergy() -> [Float] { [] }

    func purge(keepingLast keepCount: Int) {
        lock.lock(); defer { lock.unlock() }
        let newFront = max(frontOffset, ring.count - keepCount)
        if newFront > frontOffset {
            frontOffset = newFront
            if frontOffset > 16000 * 60 { ring.removeFirst(frontOffset); frontOffset = 0 }
        }
    }

    // MARK: - Audio handling

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat,
              let input = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil),
              input.frameLength > 0 else { return }

        if converter == nil { converter = AVAudioConverter(from: tapFormat, to: target) }
        guard let converter else { return }
        let ratio = target.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard convErr == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock(); ring.append(contentsOf: samples); lock.unlock()
        onSamples?(samples)
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }
}
