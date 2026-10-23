import AppKit
import SwiftUI
import AVFoundation
import Combine
import ZVONScreenshots

@MainActor
public final class VideoRecordingController: ObservableObject {
    public enum Phase { case idle, selecting, starting, recording, paused, saving }
    @Published public private(set) var phase: Phase = .idle
    @Published private(set) var elapsed = 0.0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var frames = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var message: String?
    @Published private(set) var result: URL?
    @Published var microphone: Bool { didSet { defaults.set(microphone, forKey: "video.microphone") } }
    @Published var systemAudio: Bool { didSet { defaults.set(systemAudio, forKey: "video.systemAudio") } }
    @Published var microphoneID: String { didSet { defaults.set(microphoneID, forKey: "video.microphoneID") } }
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: "video.cursor") } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: "video.fps") } }
    @Published private(set) var microphoneMuted = false
    @Published private(set) var systemMuted = false
    private let defaults = UserDefaults.standard
    private let selector = ScreenTargetSelector()
    private var engine: RecordingEngine?
    private var operation: Task<Void, Never>?
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var pendingFailure: Error?
    public var isBusy: Bool { phase != .idle }
    public var isRecording: Bool { phase == .recording || phase == .paused }
    public var canPause: Bool { isRecording && frames > 0 }
    public var canStop: Bool { phase == .starting || isRecording }
    public var savedDirectory: URL { RecordingFiles.downloads }
    var draftCount: Int { RecordingFiles.recoverableDrafts().count }

    public init() {
        defaults.register(defaults: ["video.systemAudio": true, "video.microphone": false, "video.cursor": true, "video.fps": 30])
        microphone = defaults.bool(forKey: "video.microphone")
        systemAudio = defaults.bool(forKey: "video.systemAudio")
        microphoneID = defaults.string(forKey: "video.microphoneID") ?? ""
        showsCursor = defaults.bool(forKey: "video.cursor")
        fps = defaults.integer(forKey: "video.fps") == 60 ? 60 : 30
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "Запись завершена перед переходом Mac в сон.") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            Task { @MainActor in
                guard let self, self.microphone, self.isRecording,
                      self.engine?.microphoneDeviceID == device.uniqueID else { return }
                self.stop(reason: "Микрофон отключён. Видео сохранено до отключения устройства.")
            }
        })
    }

    public func start(displayOnly: Bool = false) {
        guard !isBusy else { if phase != .selecting { showPanel() }; return }
        message = nil; result = nil; elapsed = 0; frames = 0; droppedFrames = 0; pendingFailure = nil
        microphoneMuted = false; systemMuted = false
        closePanel(); phase = .selecting
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let target = try await selector.choose(displayOnly: displayOnly, toolbar: { confirm in
                    NSHostingView(rootView: RecordingSetupView(model: self, confirm: confirm))
                }) else { phase = .idle; operation = nil; return }
                try Task.checkCancellation()
                phase = .starting; showPanel(); showStatusItem()
                var options = RecordingOptions()
                options.microphone = microphone; options.systemAudio = systemAudio
                options.microphoneID = microphoneID.isEmpty ? nil : microphoneID
                options.showsCursor = showsCursor; options.framesPerSecond = fps
                let engine = RecordingEngine(); self.engine = engine
                engine.onProgress = { [weak self] p in
                    guard let self else { return }
                    self.elapsed = p.elapsed; self.frames = p.frames; self.droppedFrames = p.dropped
                    self.microphoneLevel = p.microphone; self.systemLevel = p.system
                    self.statusItem?.button?.title = (self.phase == .paused ? "Ⅱ " : "● ") + self.clock
                }
                engine.onFailure = { [weak self] error in
                    guard let self else { return }
                    if self.phase == .starting { self.pendingFailure = error }
                    else if self.isRecording { self.stop(reason: error.localizedDescription) }
                }
                try await engine.start(target: target, options: options)
                try Task.checkCancellation()
                phase = .recording; operation = nil
                if let failure = pendingFailure { stop(reason: failure.localizedDescription) }
            } catch {
                if let engine = self.engine { _ = try? await engine.stop() }
                self.engine = nil; phase = .idle; operation = nil; removeStatusItem()
                if error is CancellationError { closePanel() }
                else { message = error.localizedDescription; showPanel() }
            }
        }
    }
    public func cancelSelection() {
        guard phase == .selecting else { return }; operation?.cancel(); selector.cancel()
    }
    public func stop(reason: String? = nil) {
        if phase == .selecting { cancelSelection(); return }
        if phase == .starting { operation?.cancel(); return }
        guard isRecording, let engine else { return }
        phase = .saving; message = reason
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await engine.stop()
                let destination = RecordingFiles.destination()
                try await RecordingFiles.export(draft, to: destination)
                result = destination
                if droppedFrames > max(5, frames / 20) {
                    message = (message.map { $0 + " " } ?? "") + "Из-за нагрузки пропущено кадров: \(droppedFrames). Для следующей записи попробуй 30 кадров/с или меньшую область."
                }
            } catch { message = error.localizedDescription }
            self.engine = nil; phase = .idle; operation = nil; removeStatusItem(); showPanel()
        }
    }
    public func togglePause() {
        guard canPause, let engine else { return }
        let paused = phase != .paused; phase = paused ? .paused : .recording
        Task { await engine.pause(paused) }
    }
    func toggleMicrophone() {
        microphoneMuted.toggle(); let muted = microphoneMuted
        Task { await engine?.muteMicrophone(muted) }
    }
    func toggleSystem() {
        systemMuted.toggle(); let muted = systemMuted
        Task { await engine?.muteSystem(muted) }
    }
    public func finishBeforeQuit() async {
        if phase == .selecting { cancelSelection() }
        else if canStop { stop() }
        if let operation { await operation.value }
    }
    public func recover() {
        guard !isBusy else { return }
        let drafts = RecordingFiles.recoverableDrafts()
        guard !drafts.isEmpty else { message = "Незавершённых записей нет."; result = nil; showPanel(); return }
        phase = .saving; message = nil; showPanel()
        operation = Task {
            var saved = 0, failures = 0
            for draft in drafts {
                do {
                    let destination = RecordingFiles.destination()
                    try await RecordingFiles.export(draft, to: destination)
                    result = destination; saved += 1
                } catch { failures += 1 }
            }
            message = "Восстановлено видео: \(saved)." + (failures > 0 ? " Не удалось восстановить: \(failures). Исходные файлы сохранены." : "")
            phase = .idle; operation = nil; showPanel()
        }
    }
    var clock: String { let seconds = Int(elapsed); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
    var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func closePanel() { panel?.orderOut(nil); panel?.contentView = nil; panel?.close(); panel = nil }
    func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("zvon.video.controls")
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: RecordingHUD(model: self))
            self.panel = panel
        }
        let size = CGSize(width: 450, height: phase == .idle ? 154 : 64)
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel?.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height), display: true)
        panel?.orderFrontRegardless()
    }
    private func showStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "● 00:00"; item.button?.toolTip = "Запись видео ZVON — остановить"
        item.button?.target = self; item.button?.action = #selector(statusPressed)
        statusItem = item
    }
    @objc private func statusPressed() { stop() }
    private func removeStatusItem() { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil }
}

private struct RecordingSetupView: View {
    @ObservedObject var model: VideoRecordingController
    var confirm: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.fill").foregroundStyle(.mint).accessibilityHidden(true)
            Toggle(isOn: $model.microphone) { Image(systemName: model.microphone ? "mic.fill" : "mic.slash") }.toggleStyle(.button)
                .help("Записать микрофон").accessibilityLabel("Микрофон")
            Menu {
                Button("Системный микрофон") { model.microphoneID = "" }
                ForEach(model.devices, id: \.uniqueID) { device in
                    Button((model.microphoneID == device.uniqueID ? "✓ " : "") + device.localizedName) { model.microphoneID = device.uniqueID; model.microphone = true }
                }
            } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }
            .menuStyle(.borderlessButton).fixedSize().help("Выбрать микрофон")
            Toggle(isOn: $model.systemAudio) { Image(systemName: model.systemAudio ? "speaker.wave.2.fill" : "speaker.slash") }.toggleStyle(.button)
                .help("Записать звук компьютера").accessibilityLabel("Звук компьютера")
            Divider().frame(height: 24)
            Menu {
                Toggle("Показывать курсор", isOn: $model.showsCursor)
                Picker("Частота кадров", selection: $model.fps) { Text("30 кадров/с").tag(30); Text("60 кадров/с").tag(60) }
                Text("MP4 · Загрузки")
            } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).fixedSize().help("Параметры видео")
            Button(action: confirm) { Label("Записать", systemImage: "record.circle.fill").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent).tint(.red).accessibilityLabel("Начать запись видео")
        }
        .controlSize(.large).padding(.horizontal, 16).frame(height: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.15)))
        .environment(\.colorScheme, .dark).fixedSize()
    }
}

private struct RecordingHUD: View {
    @ObservedObject var model: VideoRecordingController
    var body: some View {
        Group {
            if model.phase == .idle { result }
            else { controls }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
    private var controls: some View {
        HStack(spacing: 16) {
            if model.phase == .saving || model.phase == .starting { ProgressView().controlSize(.small) }
            else { Circle().fill(model.phase == .paused ? Color.orange : Color.red).frame(width: 8, height: 8) }
            Text(model.phase == .saving ? "Сохраняю…" : model.phase == .starting ? "Подготовка…" : model.clock)
                .monospacedDigit().fontWeight(.medium)
            if model.phase == .paused { Text("Пауза").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if model.microphone {
                Button { model.toggleMicrophone() } label: { HStack(spacing: 4) {
                    Image(systemName: model.microphoneMuted ? "mic.slash" : "mic.fill")
                    meter(model.microphoneMuted ? 0 : model.microphoneLevel)
                } }
                    .help("Включить или выключить микрофон").disabled(!model.isRecording)
                    .accessibilityLabel("Отключить микрофон")
            }
            if model.systemAudio {
                Button { model.toggleSystem() } label: { HStack(spacing: 4) {
                    Image(systemName: model.systemMuted ? "speaker.slash" : "speaker.wave.2")
                    meter(model.systemMuted ? 0 : model.systemLevel)
                } }
                    .help("Включить или выключить звук компьютера").disabled(!model.isRecording)
                    .accessibilityLabel("Отключить звук компьютера")
            }
            Button { model.togglePause() } label: { Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill") }
                .disabled(!model.canPause).help(model.phase == .paused ? "Продолжить" : "Пауза")
                .accessibilityLabel(model.phase == .paused ? "Продолжить видео" : "Пауза видео")
            Button { model.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                .disabled(!model.canStop).help("Остановить и сохранить в Загрузки").accessibilityLabel("Остановить видео")
        }.buttonStyle(.plain).font(.system(size: 15)).padding(.horizontal, 20)
    }
    private func meter(_ level: Float) -> some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.12))
            Capsule().fill(level > 0.9 ? Color.orange : Color.mint)
                .frame(height: max(2, CGFloat(min(1, sqrt(max(0, level)))) * 16))
        }.frame(width: 3, height: 16).accessibilityHidden(true)
    }
    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.result == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(model.result == nil ? .orange : .mint)
                Text(model.result == nil ? "Запись видео" : "Видео в Загрузках").fontWeight(.semibold)
                Spacer()
                Button { model.closePanel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть")
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            if let url = model.result {
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button("Смотреть") { NSWorkspace.shared.open(url) }
                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    Button("Копировать файл") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
                }.buttonStyle(.bordered).controlSize(.small)
                .onDrag { NSItemProvider(contentsOf: url)! }
            } else if model.draftCount > 0 {
                Button("Восстановить запись") { model.recover() }.buttonStyle(.bordered)
            }
        }.padding(18)
    }
}
