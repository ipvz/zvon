import AppKit
import Combine

@MainActor
final class CodexUsageStore: ObservableObject {
    static let shared = CodexUsageStore()
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "codexUsageEnabled")
            if enabled { lastAttempt = nil; suspended = false; start() } else { stop(); snapshot = nil; error = nil }
        }
    }
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var error: CodexUsageError?
    @Published private(set) var isRefreshing = false
    private let client: any CodexUsageReading
    private let defaults: UserDefaults
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var lastAttempt: Date?
    private var suspended = false

    init(client: any CodexUsageReading = CodexUsageClient(), defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.client = client; self.defaults = defaults; self.now = now
        enabled = defaults.object(forKey: "codexUsageEnabled") as? Bool ?? true
    }

    func start() {
        guard enabled, observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true; self?.cancelRequest() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; self?.lastAttempt = nil; self?.refresh() }
        })
        refresh()
    }

    func stop() {
        cancelRequest()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    private func cancelRequest() {
        generation += 1; task?.cancel(); task = nil
        timer?.invalidate(); timer = nil; isRefreshing = false
    }
    func refresh() {
        guard enabled, !suspended, task == nil else { return }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < 30 { return }
        timer?.invalidate(); timer = nil
        lastAttempt = now(); isRefreshing = true
        generation += 1
        let expected = generation, client = client
        task = Task { [weak self] in
            let result: Result<CodexUsageSnapshot, Error>
            do { result = .success(try await client.read()) }
            catch { result = .failure(error) }
            guard let self, expected == generation, !Task.isCancelled else { return }
            switch result {
            case .success(let snapshot): self.snapshot = snapshot; error = nil
            case .failure(let failure):
                error = failure as? CodexUsageError ?? .unavailable
                if error == .signedOut || error == .unsupportedAccount || error == .notInstalled { snapshot = nil }
            }
            isRefreshing = false; task = nil
            scheduleRefresh()
        }
    }
    private func scheduleRefresh() {
        guard enabled, !suspended else { return }
        var delay: TimeInterval = 300
        if error == nil, let reset = snapshot?.bucket.windows.compactMap(\.resetDate).filter({ $0 > Date() }).min() {
            delay = min(delay, max(31, reset.timeIntervalSinceNow + 2))
        }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(15, delay / 10)
    }
    func remaining(at date: Date = Date()) -> Int? {
        guard error == nil, let snapshot, !snapshot.isStale(at: date) else { return nil }
        return snapshot.bucket.remainingPercent
    }
    var tooltip: String {
        guard let remaining = remaining() else {
            let status = error?.message ?? (isRefreshing ? L("Обновляем лимиты…", "Refreshing usage…")
                : snapshot?.isStale(at: Date()) == true ? L("Данные устарели", "Data is out of date")
                : L("Процентный лимит недоступен", "Percentage allowance unavailable"))
            return "Codex · " + status
        }
        let period = snapshot?.bucket.windows.min(by: { $0.remainingPercent < $1.remainingPercent })?.period ?? ""
        return L("Codex · осталось \(remaining)% · \(period)", "Codex · \(remaining)% remaining · \(period)")
    }
    deinit {
        task?.cancel(); timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
