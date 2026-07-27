import Foundation
import SwiftUI
import KeyboardShortcuts

/// UI-facing state. Coordinates `ModelManager` (files on disk) and `SpeechPipeline`
/// (in-memory model + live stream), bridging async work to `@Published` properties.
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()
    private static let loadTimeout: Double = 180   // seconds before a load is declared hung

    // Session
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var status: PipelineStatus = .idle
    @Published var lines: [TranscriptLine] = []
    @Published var levels: [Float] = []        // mic RMS
    @Published var levelsThem: [Float] = []    // system-audio RMS
    @Published var widgetSize: WidgetSize = .puck
    @Published var widgetHidden: Bool { didSet { UserDefaults.standard.set(widgetHidden, forKey: "widgetHidden") } }
    @Published var showMenuBar: Bool { didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var recordingStartedAt: Date?
    @Published var pendingOpenSession: UUID?    // set by the menu-bar "Недавние" → MeetingView opens it
    @Published var pendingOpenSettings = false  // ⌘, / menu-bar Настройки → MeetingView opens settings in-window
    @Published var pendingOpenTasks = false     // "Открыть" on the task-created card → MeetingView shows Задачи
    @Published var pendingOpenTaskId: UUID?     // tasks-menu row click → open Задачи scrolled to this task

    // Roled transcript coordinator
    private var finals: [TranscriptLine] = []
    private var partials: [Speaker: TranscriptLine] = [:]
    private var nextLineId: UInt64 = 0
    // Global-timeline base so utterances stay ordered across pause/resume segments
    // (each streamer restarts its own clock at 0 on resume).
    private var segmentBaseSec: Double = 0
    private var segmentStartedAt: Date?

    // Calendar context (from EventKit; a Yandex CalDAV account surfaces here too)
    @Published var meetingTitle: String?         // auto-title from the current calendar event
    var currentEvent: CalendarEvent?             // attendees + join link for the live session
    @Published var calendarEnabled = true { didSet { UserDefaults.standard.set(calendarEnabled, forKey: "calendarEnabled") } }

    // Live LLM notes
    @Published var notes = MeetingNotes()
    @Published var notesGenerating = false
    @Published var notesError: String?          // surfaced LLM failure (nil = fine)
    private var noteDebounce: Task<Void, Never>?

    // Ask-about-the-meeting (⌘K command field)
    @Published var asking = false
    @Published var askQuestion: String?
    @Published var askAnswer: String?
    @Published var askError: String?
    @Published var askSources: [SessionRecord] = []   // cited meetings when asking over the whole archive

    // Settings → connection test: "" idle · "…" testing · "ok" · else = error message
    @Published var llmTest = ""

    // Push-to-talk dictation (Wispr Flow style)
    @Published var isDictating = false          // UI: mic hot for a hold-to-dictate session
    @Published var dictationCard: String?       // "no editable field" card text (auto-copied)
    @Published var dictationCardIsTask = false  // card is a "task created" confirmation, not the copy card
    @Published var dictationCardIsCommand = false   // card is a "command run" toast
    @Published var pendingCommand: CommandItem?     // a needsConfirm command awaiting a tap to run
    @Published var dictationHistory: [DictationEntry] = []
    private var dictating = false               // internal: current session is a dictation
    private var cardTask: Task<Void, Never>?
    private static let historyKey = "dictationHistory"
    private static let historyLimit = 100

    // Model readiness (background prewarm)
    @Published var preparing = false
    @Published var modelReady = false
    @Published var prepareError: String?
    @Published var preparingStartedAt: Date?

    let models = ModelManager()

    // Settings (persisted).
    @Published var selectedModel: String { didSet { persist(); onModelChanged() } }
    @Published var language: String { didSet { persist() } }        // "auto" | "ru" | "en"
    @Published var compute: ComputePreference { didSet { persistCompute(); onComputeChanged() } }
    @Published var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    @Published var llmProvider: LLMProvider {
        didSet { UserDefaults.standard.set(llmProvider.rawValue, forKey: "llmProvider"); llmTest = "" }
    }
    @Published var llmEndpoint: String { didSet { persist() } }
    @Published var llmModel: String { didSet { persist() } }
    @Published var dictationTrigger: DictationTrigger {
        didSet {
            UserDefaults.standard.set(dictationTrigger.rawValue, forKey: "dictationTrigger")
            if dictating { stopDictation() }   // avoid a stuck hold when the trigger changes
        }
    }
    @Published var dictationMode: DictationMode {
        didSet { UserDefaults.standard.set(dictationMode.rawValue, forKey: "dictationMode") }
    }
    @Published var themePref: ThemePref {
        didSet { UserDefaults.standard.set(themePref.rawValue, forKey: "themePref") }
    }
    // Settings → AI-модель → Задачи.
    @Published var summariesEnabled: Bool {          // «Саммари и Итог» — live notes + ✦ Итог
        didSet { UserDefaults.standard.set(summariesEnabled, forKey: "summariesEnabled") }
    }
    @Published var taskExtractionEnabled: Bool {     // «Извлечение задач» — keyword-triggered voice tasks
        didSet { UserDefaults.standard.set(taskExtractionEnabled, forKey: "taskExtractionEnabled") }
    }
    // Settings → Горячие клавиши → Обработка диктовки. AI cleanup of push-to-talk dictation ONLY.
    @Published var aiDictationEnabled: Bool {
        didSet { UserDefaults.standard.set(aiDictationEnabled, forKey: "aiDictationEnabled") }
    }
    @Published var aiDictationStyle: DictationStyle {
        didSet { UserDefaults.standard.set(aiDictationStyle.rawValue, forKey: "aiDictationStyle") }
    }
    // Settings → Речь → «Улучшать транскрипт через ИИ» (confidence-gated GER, offloaded to the LLM).
    @Published var aiTranscriptRepairEnabled: Bool {
        didSet { UserDefaults.standard.set(aiTranscriptRepairEnabled, forKey: "aiTranscriptRepairEnabled") }
    }
    static let repairConfidence: Float = 0.70   // only finals below this (uncertain) get sent for repair
    @Published var dictationProcessing = false       // AI polish running → HUD shows the «обрабатываю» pill
    @Published var totalDictatedWords: Int {         // lifetime word count (Wispr-style stat)
        didSet { UserDefaults.standard.set(totalDictatedWords, forKey: "totalDictatedWords") }
    }
    @Published var onboardingDone: Bool {            // first-run permissions walkthrough completed
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }

    private var pipeline: SpeechPipeline!
    private var runTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var stopping = false               // a stop was requested → finalize on stream end
    private var pendingSegmentAdvance: Double = 0   // paused segment's duration, applied on resume
    private(set) var currentSessionId = UUID() // links live tasks/session to the archived record

    init() {
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: "selectedModel") ?? ModelCatalog.defaultModelID
        language = d.string(forKey: "language") ?? "ru"
        // Default GPU: loads reliably every time. ANE is faster at runtime but its first-run
        // compile is long/opaque — offered as an opt-in in Settings.
        compute = ComputePreference(rawValue: d.string(forKey: "compute") ?? "") ?? .gpu
        captureMode = CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .micOnly
        // Ship WITHOUT a baked-in endpoint (a private dev server must never be the default). Default
        // provider is .hf with an EMPTY endpoint: fresh users pick a provider + key in Settings; an
        // existing user who had a custom endpoint keeps it (providerEndpoint(.hf) == llmEndpoint).
        llmProvider = LLMProvider(rawValue: d.string(forKey: "llmProvider") ?? "") ?? .hf
        llmEndpoint = d.string(forKey: "llmEndpoint") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? ""
        dictationTrigger = DictationTrigger(rawValue: d.string(forKey: "dictationTrigger") ?? "") ?? .combo
        dictationMode = DictationMode(rawValue: d.string(forKey: "dictationMode") ?? "") ?? .hold
        themePref = ThemePref(rawValue: d.string(forKey: "themePref") ?? "") ?? .dark
        widgetHidden = d.bool(forKey: "widgetHidden")
        showMenuBar = d.object(forKey: "showMenuBar") == nil ? true : d.bool(forKey: "showMenuBar")
        summariesEnabled = d.object(forKey: "summariesEnabled") == nil ? true : d.bool(forKey: "summariesEnabled")
        taskExtractionEnabled = d.object(forKey: "taskExtractionEnabled") == nil ? true : d.bool(forKey: "taskExtractionEnabled")
        aiDictationEnabled = d.bool(forKey: "aiDictationEnabled")   // off by default (opt-in, adds a beat of latency)
        aiDictationStyle = DictationStyle(rawValue: d.string(forKey: "aiDictationStyle") ?? "") ?? .plain
        aiTranscriptRepairEnabled = d.bool(forKey: "aiTranscriptRepairEnabled")   // off by default (opt-in)
        totalDictatedWords = d.integer(forKey: "totalDictatedWords")
        onboardingDone = d.bool(forKey: "onboardingDone")
        calendarEnabled = d.object(forKey: "calendarEnabled") == nil ? true : d.bool(forKey: "calendarEnabled")

        pipeline = SpeechPipeline(
            onStatus: { [weak self] status in
                Task { @MainActor in self?.applyStatus(status) }
            },
            onEvent: { [weak self] speaker, event in
                Task { @MainActor in self?.handleEvent(speaker, event) }
            }
        )

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.toggle()
        }
        // Dictation trigger via the KeyboardShortcuts combo. Hold-mode = push-to-talk;
        // toggle-mode = press on/off.
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            guard let self else { return }
            if self.dictationMode == .toggle { self.toggleDictation() } else { self.startDictation() }
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            guard let self else { return }
            if self.dictationMode == .hold { self.stopDictation() }
        }
        KeyboardShortcuts.onKeyUp(for: .summarize) { [weak self] in
            self?.regenerateNotes()
        }
        loadHistory()

        DebugLog.log("store init; model=\(selectedModel) compute=\(compute.rawValue) downloaded=\(models.isDownloaded(selectedModel))")
        // Warm the model at app launch — independent of whether the window is shown.
        prepareActiveModelIfDownloaded()
    }

    var hasTranscript: Bool { !lines.isEmpty }
    var latestLine: TranscriptLine? { lines.last }
    func latestLine(for speaker: Speaker) -> TranscriptLine? { lines.last { $0.speaker == speaker } }

    var canRecord: Bool { isRecording || stage == .ready }
    func setWidgetSize(_ size: WidgetSize) { widgetSize = size }

    // MARK: - Roled transcript coordinator

    private func handleEvent(_ speaker: Speaker, _ event: TranscriptionEvent) {
        switch event {
        case .meter(let energy):
            guard isRecording else { return }
            if speaker == .me { levels = energy } else { levelsThem = energy }
        case .interim(let text):
            guard isRecording else { return }
            if text.isEmpty {
                partials[speaker] = nil
            } else {
                let t = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                partials[speaker] = TranscriptLine(id: speaker == .me ? .max - 1 : .max - 2,
                                                   speaker: speaker, text: text, isFinal: false, startSec: t)
            }
            rebuildLines()
        case .final(let text, let startSec, let confidence):
            // Not guarded by isRecording: the last utterance is flushed *after* stop(), and we
            // must not drop it (this is what lost replies on stop, and dictation needs it).
            partials[speaker] = nil
            nextLineId += 1
            let lineId = nextLineId
            let corrected = GlossaryStore.shared.correct(text)   // local glossary fix on the final
            finals.append(TranscriptLine(id: lineId, speaker: speaker, text: corrected, isFinal: true, startSec: startSec + segmentBaseSec))
            finals.sort { $0.startSec < $1.startSec }
            rebuildLines()
            scheduleNotes()
            if speaker == .me { detectVoiceTask(corrected) }   // only YOUR speech makes tasks — not the other party's
            // Confidence-gated GER: only send genuinely uncertain finals to the LLM for repair (offloaded,
            // few calls). Meetings only (dictation has its own cleanup).
            if aiTranscriptRepairEnabled, !dictating, confidence < Self.repairConfidence { repairFinal(id: lineId, text: corrected) }
        case .ended:
            partials[speaker] = nil
            rebuildLines()
            // Finalization (dictation insert / meeting archive) is driven from the run task after
            // the stream fully drains, so the tail utterance is always included — not from here.
        }
    }

    private func rebuildLines() {
        var out = finals
        if let p = partials[.me] { out.append(p) }
        if let p = partials[.them] { out.append(p) }
        lines = out
    }

    typealias LLMConfig = (endpoint: String, model: String, key: String?, style: LLMAPIStyle)

    private func llmConfig() -> LLMConfig {
        let p = llmProvider
        let key = p.needsKey ? Keychain.get(account: p.keyAccount) : nil
        return (providerEndpoint(p), providerModel(p), key, p.apiStyle)
    }

    /// Endpoint for a provider: fixed cloud URL, or the user's field for hf/custom.
    func providerEndpoint(_ p: LLMProvider) -> String { p.fixedEndpoint ?? llmEndpoint }

    /// Model id for a provider: hf/custom reuse `llmModel`; others store per-provider (default fallback).
    func providerModel(_ p: LLMProvider) -> String {
        let raw: String = (p == .hf || p == .custom)
            ? llmModel
            : (UserDefaults.standard.string(forKey: p.modelKey) ?? "")
        let m = raw.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? p.defaultModel : m
    }
    /// Raw stored model id (may be empty → the field shows `defaultModel` as placeholder).
    func rawProviderModel(_ p: LLMProvider) -> String {
        (p == .hf || p == .custom) ? llmModel : (UserDefaults.standard.string(forKey: p.modelKey) ?? "")
    }
    func setProviderModel(_ p: LLMProvider, _ value: String) {
        if p == .hf || p == .custom { llmModel = value }
        else { UserDefaults.standard.set(value, forKey: p.modelKey) }
    }

    private func transcriptText() -> String {
        finals.map { "\($0.speaker.title): \($0.text)" }.joined(separator: "\n")
    }

    /// Instant local task creation when the speaker says a trigger phrase — complements the LLM
    /// extraction with deterministic "I said it → it exists" feedback. Meetings only.
    /// STEM match, not exact phrases — the ASR spells the verb many ways («создай/создая/создать
    /// задачу»), so we key on the noun stem «задач» (explicit) and reminder stems (soft), not the verb.
    private static let taskStems = ["задач"]                 // задача/задачу/задачи/задаче…
    private static let reminderStems = ["напомн", "не забуд"] // напомни/напомнить, не забудь/забыть

    /// Cheap pre-filter: a task-word or reminder stem is present (LLM then confirms via `parseTask`).
    /// A question is never a command ("напомни, когда встреча?").
    func taskCommand(_ text: String) -> String? { Self.remainderAfterStem(text, Self.taskStems + Self.reminderStems) }
    /// Only the explicit «…задач…» form (used as the LLM-down fallback — reminders need the LLM).
    func explicitTaskCommand(_ text: String) -> String? { Self.remainderAfterStem(text, Self.taskStems) }

    /// Voice-command verbs — «открой/запусти/включи …». Keyed on stems so the Russian ASR's many
    /// spellings all match.
    private static let commandStems = ["откр", "запус", "вкл", "выкл", "переключ", "покаж",
                                       "open", "launch", "run", "start"]

    /// A command only fires on a SHORT utterance whose FIRST word is a command verb — so a verb that
    /// slips into the middle of a longer dictated sentence never triggers an action. Returns the
    /// target phrase after the verb, or nil (not a command).
    func commandTarget(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("?") else { return nil }
        let strip = CharacterSet(charactersIn: " ,.:;!?«»\"—-")
        let words = trimmed.split(whereSeparator: { " \n\t".contains($0) }).map(String.init)
        guard words.count >= 2, words.count <= 5 else { return nil }        // «открой почту», not a paragraph
        let first = words[0].lowercased().trimmingCharacters(in: strip)
        guard Self.commandStems.contains(where: { first.hasPrefix($0) }) else { return nil }   // verb must lead
        var after = words.dropFirst().joined(separator: " ").trimmingCharacters(in: strip)
        if after.lowercased().hasPrefix("мне ") { after = String(after.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return after.isEmpty ? nil : after
    }

    private static func remainderAfterStem(_ text: String, _ stems: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("?") else { return nil }
        let low = trimmed.lowercased()
        // Earliest stem match; keep its end so we can skip to the end of that word.
        var lower: String.Index?, upper: String.Index?
        for stem in stems {
            if let r = low.range(of: stem), lower == nil || r.lowerBound < lower! { lower = r.lowerBound; upper = r.upperBound }
        }
        guard var idx = upper else { return nil }
        while idx < low.endIndex, !" ,.:;—-\t\n".contains(low[idx]) { idx = low.index(after: idx) }  // past the whole word
        let offset = low.distance(from: low.startIndex, to: idx)
        let tIdx = trimmed.index(trimmed.startIndex, offsetBy: offset)
        var after = String(trimmed[tIdx...]).trimmingCharacters(in: CharacterSet(charactersIn: " :—-,.\t"))
        if after.lowercased().hasPrefix("мне ") { after = String(after.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return after.isEmpty ? trimmed : after
    }

    /// Generative Error Repair for a low-confidence final: the LLM fixes only clear recognition errors
    /// (offloaded), then we swap the line's text. Strong anti-over-correction in the prompt + a length
    /// guard so it can't rewrite/hallucinate. Nearby lines give the model context.
    private func repairFinal(id: UInt64, text: String) {
        let cfg = llmConfig()
        guard !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let context = finals.suffix(6).map { "\($0.speaker.title): \($0.text)" }.joined(separator: "\n")
        Task { [weak self] in
            guard let fixed = try? await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key,
                                                       style: cfg.style, glossary: GlossaryStore.shared.promptFragment)
                .repairTranscript(text, context: context) else { return }
            guard let self else { return }
            let clean = GlossaryStore.shared.correct(fixed)
            guard !clean.isEmpty, clean != text, let i = self.finals.firstIndex(where: { $0.id == id }) else { return }
            self.finals[i].text = clean
            self.rebuildLines()
        }
    }

    private func detectVoiceTask(_ text: String) {
        guard taskExtractionEnabled, !dictating, taskCommand(text) != nil else { return }
        let cfg = llmConfig()
        let session = currentSessionId
        guard !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            // No LLM to gate → keyword-only best-effort (questions already excluded in taskCommand).
            if let raw = taskCommand(text) { _ = TaskStore.shared.addVoice(GlossaryStore.shared.correct(raw), sessionId: session) }
            return
        }
        // The LLM DECIDES if it's really a task (vetoes questions / messages to others), then extracts it.
        let context = transcriptText()
        let command = text
        Task { [weak self] in
            var item: ActionItem?
            var errored = false
            do {
                item = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key,
                                               style: cfg.style, glossary: GlossaryStore.shared.promptFragment)
                    .parseTask(command: command, context: context)   // nil = LLM said "not a task"
            } catch { errored = true }
            guard let self else { return }
            // LLM unreachable but the phrasing is an explicit "…задачу" → still create (don't drop).
            if item == nil, errored, let raw = self.explicitTaskCommand(command) {
                item = ActionItem(text: GlossaryStore.shared.correct(raw), owner: nil, due: nil)
            }
            guard let item else { return }
            let clean = GlossaryStore.shared.correct(item.text.trimmingCharacters(in: .whitespaces))
            guard !clean.isEmpty, let created = TaskStore.shared.addVoice(clean, sessionId: session) else { return }
            TaskStore.shared.edit(created.id) { $0.owner = item.ownerClean; $0.due = item.dueClean }
        }
    }

    /// Debounced live-notes generation from the finalized transcript.
    private var lastNotesAt: Date?
    private var lastNotesFinals = 0
    private static let notesMinInterval: TimeInterval = 45   // don't refresh the live итог more often than this

    private func scheduleNotes() {
        guard summariesEnabled else { return }  // «Саммари и Итог» off → no live notes
        guard !dictating else { return }        // dictation isn't a meeting — no notes
        guard finals.count >= 2 else { return }
        noteDebounce?.cancel()
        let transcript = transcriptText()
        let cfg = llmConfig()
        let finalsNow = finals.count
        noteDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)   // wait for a real pause (7s quiet)
            if Task.isCancelled { return }
            guard let self else { return }
            // Throttle: at most once per ~45s — unless a lot of new content accrued (≥20 finals),
            // so long silent stretches don't waste calls and the итог doesn't churn every pause.
            let elapsed = self.lastNotesAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let newFinals = finalsNow - self.lastNotesFinals
            guard elapsed >= Self.notesMinInterval || newFinals >= 20 else { return }
            await self.runNotes(transcript: transcript, cfg: cfg)
        }
    }

    /// Manual "Обновить заметки" — runs immediately (needs at least one final).
    func regenerateNotes() {
        guard finals.count >= 1, !notesGenerating else { return }
        noteDebounce?.cancel()
        let transcript = transcriptText()
        let cfg = llmConfig()
        noteDebounce = Task { [weak self] in await self?.runNotes(transcript: transcript, cfg: cfg) }
    }

    private func runNotes(transcript: String, cfg: LLMConfig) async {
        guard !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty else { return }   // no endpoint → nothing leaves the device
        lastNotesAt = Date()               // reset the auto-refresh throttle (covers manual ✦ Итог too)
        lastNotesFinals = finals.count
        notesGenerating = true
        defer { notesGenerating = false }
        do {
            let result = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style,
                                                 glossary: GlossaryStore.shared.promptFragment)
                .generate(transcript: transcript)
            if !result.isEmpty { notes = result }   // tasks come only from spoken triggers, not ambient extraction
            notesError = nil
        } catch {
            if Task.isCancelled { return }   // superseded by a newer request → not a real error
            notesError = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            DebugLog.log("notes error: \(notesError ?? "")")
        }
    }

    // MARK: - Ask about the meeting

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askQuestion = q
        askAnswer = nil
        askError = nil
        guard finals.count >= 1 else {
            askError = "Пока нет транскрипта — начните запись, чтобы задавать вопросы по встрече."
            return
        }
        asking = true
        let cfg = llmConfig()
        let transcript = transcriptText()
        Task { [weak self] in
            do {
                let answer = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style,
                                                     glossary: GlossaryStore.shared.promptFragment)
                    .ask(question: q, transcript: transcript)
                guard let self else { return }
                self.askAnswer = answer.isEmpty ? "Пустой ответ модели." : answer
                self.asking = false
            } catch {
                guard let self else { return }
                self.askError = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self.asking = false
            }
        }
    }

    func dismissAsk() {
        askQuestion = nil
        askAnswer = nil
        askError = nil
        askSources = []
        asking = false
    }

    /// Run a recipe-lens over the given meeting material → a finished artifact (offloaded to the LLM).
    func runRecipe(instruction: String, material: String) async throws -> String {
        let cfg = llmConfig()
        guard !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty else { throw LLMError.badURL }
        return try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style,
                                       glossary: GlossaryStore.shared.promptFragment)
            .runRecipe(instruction: instruction, material: material)
    }

    /// NL question over the WHOLE archive (lightweight: keyword+recency retrieval over stored sessions
    /// → compact summaries → one offloaded LLM call with citations). No embeddings, no local model.
    // MARK: - Space digest ("summary of summaries")

    @Published var spaceSummarizing: Set<UUID> = []
    @Published var spaceSummaryError: [UUID: String] = [:]

    /// Roll every member meeting's summary + decisions into one project digest via the LLM, cached on the Space.
    func summarizeSpace(_ id: UUID) {
        guard !spaceSummarizing.contains(id), let sp = SpaceStore.shared.space(id) else { return }
        let members = SessionStore.shared.sessions.filter { sp.meetingIds.contains($0.id) }
        guard !members.isEmpty else { spaceSummaryError[id] = "Нет встреч для сводки."; return }

        let material = members.map { s -> String in
            let dur = s.durationSec.map { " · \(Int(($0 / 60).rounded())) мин" } ?? ""
            var b = "## \(s.title) — \(Self.archiveDate.string(from: s.date))\(dur)"
            let sum = (s.noteSummary ?? []).map { "• \($0)" }.joined(separator: "\n")
            if !sum.isEmpty { b += "\nИтог:\n\(sum)" }
            let dec = (s.noteDecisions ?? []).map { "• \($0)" }.joined(separator: "\n")
            if !dec.isEmpty { b += "\nРешения:\n\(dec)" }
            return b
        }.joined(separator: "\n\n")

        let instruction = """
        Собери ОБЩУЮ СВОДКУ по проекту «\(sp.name)» на основе итогов всех встреч ниже (\(members.count) шт).
        Разделы: краткое резюме проекта; ключевые темы и прогресс; принятые решения; открытые вопросы и следующие шаги.
        Пиши сжато, по делу, на языке встреч. Простым текстом с абзацами и списками через тире — без markdown-заголовков и символов #/*.
        """

        spaceSummaryError[id] = nil
        spaceSummarizing.insert(id)
        let cfg = llmConfig()
        Task { [weak self] in
            do {
                let out = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key,
                                                  style: cfg.style, glossary: GlossaryStore.shared.promptFragment)
                    .runRecipe(instruction: instruction, material: material)
                guard let self else { return }
                SpaceStore.shared.setSummary(id, out)
                self.spaceSummarizing.remove(id)
            } catch {
                guard let self else { return }
                self.spaceSummaryError[id] = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self.spaceSummarizing.remove(id)
            }
        }
    }

    func askArchive(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askQuestion = q; askAnswer = nil; askError = nil; askSources = []
        let all = SessionStore.shared.sessions
        guard !all.isEmpty else { askError = "Архив пуст — проведите встречи, чтобы спрашивать по истории."; return }

        let terms = q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        func score(_ s: SessionRecord) -> Int {
            let head = (s.title + " " + (s.noteSummary?.joined(separator: " ") ?? "")).lowercased()
            let body = (s.transcript ?? "").lowercased()
            return terms.reduce(0) { $0 + (head.contains($1) ? 3 : 0) + (body.contains($1) ? 1 : 0) }
        }
        let ranked = all.enumerated().map { (i, s) in (s: s, score: score(s), idx: i) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.idx < $1.idx }   // score desc, then newer
        var chosen = ranked.filter { $0.score > 0 }.prefix(8).map(\.s)
        if chosen.isEmpty { chosen = Array(all.prefix(6)) }   // no keyword hit → recent meetings
        askSources = chosen

        let context = chosen.map { s -> String in
            let head = "[Встреча: \(s.title) · \(Self.archiveDate.string(from: s.date))]"
            let sum = (s.noteSummary ?? []).map { "• \($0)" }.joined(separator: "\n")
            return sum.isEmpty ? head + "\n" + String((s.transcript ?? "").prefix(600)) : head + "\n" + sum
        }.joined(separator: "\n\n")

        asking = true
        let cfg = llmConfig()
        Task { [weak self] in
            do {
                let answer = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style,
                                                     glossary: GlossaryStore.shared.promptFragment)
                    .askArchive(question: q, context: context)
                guard let self else { return }
                self.askAnswer = answer.isEmpty ? "Пустой ответ модели." : answer
                self.asking = false
            } catch {
                guard let self else { return }
                self.askError = (error as? LLMError)?.errorDescription ?? error.localizedDescription
                self.asking = false
            }
        }
    }
    private static let archiveDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"; return f
    }()

    // MARK: - Connection test (Settings)

    func testLLM() {
        llmTest = "…"
        let cfg = llmConfig()
        Task { [weak self] in
            do {
                try await LLMClient(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style).ping()
                self?.llmTest = "ok"
            } catch {
                self?.llmTest = (error as? LLMError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Single stage the main window renders.
    var stage: AppStage {
        if isRecording {
            switch status {
            case .downloading(let f): return .downloading(f)
            case .loadingModel, .idle: return .preparing
            case .listening: return .listening
            case .error(let m): return .error(m)
            }
        }
        if let e = prepareError { return .error(e) }
        if case .downloading(let f) = models.state(selectedModel) { return .downloading(f) }
        if !models.isDownloaded(selectedModel) { return .needsModel }
        if preparing { return .preparing }
        if modelReady { return .ready }
        return .preparing
    }

    // MARK: - Lifecycle

    func onAppear() {
        prepareActiveModelIfDownloaded()
        startMeetingRadar()
    }

    // MARK: - Meeting radar (calendar-driven "a call is on — record it?" nudge)

    @Published var suggestedMeeting: CalendarEvent?
    private var dismissedMeetingKey: String?
    private var pendingMeeting: CalendarEvent?      // event from the radar banner, applied once recording starts
    private var radarTask: Task<Void, Never>?

    private func startMeetingRadar() {
        radarTask?.cancel()
        radarTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkMeetingRadar()
                try? await Task.sleep(nanoseconds: 60_000_000_000)   // re-check every 60s
            }
        }
    }

    private func checkMeetingRadar() async {
        guard calendarEnabled, CalendarService.shared.authorized, !isRecording, !isDictating else {
            suggestedMeeting = nil; return
        }
        // Only ongoing, call-like meetings (a join link or invitees) — never a «Занят»/Focus block,
        // and never one the user already dismissed.
        guard let ev = await CalendarService.shared.currentOrNext(lookahead: 0),
              ev.start <= Date(), ev.end > Date(),
              (ev.isCall || !ev.attendees.isEmpty),
              ev.key != dismissedMeetingKey else {
            suggestedMeeting = nil; return
        }
        suggestedMeeting = ev
    }

    func dismissSuggestedMeeting() {
        dismissedMeetingKey = suggestedMeeting?.key
        suggestedMeeting = nil
    }

    /// «Записать» on the radar banner: carry the exact event the user saw into the new recording.
    /// Stashed in `pendingMeeting` because `start()` resets session state asynchronously inside the
    /// run task — setting `meetingTitle` here directly would be clobbered by that reset.
    func recordSuggestedMeeting() {
        guard let ev = suggestedMeeting, canRecord else { return }
        suggestedMeeting = nil
        pendingMeeting = ev
        start()
    }

    private func prepareActiveModelIfDownloaded() {
        let variant = selectedModel
        guard models.isDownloaded(variant), !modelReady, !preparing else { return }
        beginPreparing()
        let compute = compute
        prepareTask = Task { [weak self] in
            guard let self else { return }
            await self.load(variant: variant, folder: ModelPaths.folder(for: variant), compute: compute)
        }
    }

    /// Download the active model (with progress) then warm it — used by the main-window CTA.
    func downloadAndPrepare() {
        let variant = selectedModel
        guard !preparing else { return }
        beginPreparing()
        let compute = compute
        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                DebugLog.log("download begin \(variant)")
                let folder = try await self.models.ensureDownloaded(variant)
                await self.load(variant: variant, folder: folder, compute: compute)
            } catch {
                DebugLog.log("download failed: \(error.localizedDescription)")
                self.failPreparing(error.localizedDescription)
            }
        }
    }

    /// Load a model into memory with a hard timeout so the UI can never hang forever.
    private func load(variant: String, folder: URL, compute: ComputePreference) async {
        let start = Date()
        DebugLog.log("prewarm begin \(variant) compute=\(compute.rawValue)")
        do {
            try await withTimeout(Self.loadTimeout) { [pipeline] in
                try await pipeline!.prepare(variant: variant, folder: folder, compute: compute)
            }
            let dt = Date().timeIntervalSince(start)
            DebugLog.log("prewarm DONE \(variant) in \(String(format: "%.1f", dt))s")
            preparing = false
            modelReady = true
        } catch {
            DebugLog.log("prewarm FAILED: \(error.localizedDescription)")
            failPreparing(error.localizedDescription)
        }
    }

    // MARK: - Recording

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        isPaused = false
        stopping = false
        status = .loadingModel
        recordingStartedAt = Date()
        launchRunTask(reset: true)
    }

    /// One capture segment, serialized after the prior session's teardown so back-to-back
    /// dictations can't interleave and no straggler event lands in the wrong session.
    private func launchRunTask(reset: Bool) {
        let prior = runTask
        let dict = dictating            // capture THIS session's mode (a prior finalize may clear it)
        runTask = Task { [weak self] in
            _ = await prior?.value      // drain the previous session fully (tail flush + finalize)
            guard let self, self.isRecording, !self.isPaused else { return }
            self.dictating = dict
            self.isDictating = dict
            if reset { self.resetSessionState() }
            if let pm = self.pendingMeeting {           // «Записать» on the radar banner — use that exact event
                self.pendingMeeting = nil
                self.meetingTitle = pm.title.isEmpty ? nil : pm.title
                self.currentEvent = pm
            } else if !dict {
                self.fetchCalendarContext()             // non-blocking auto-title from the calendar
            }
            await self.streamSession()
            await Task.yield()          // let the trailing .final/.ended land on the main actor first
            guard self.stopping else { return }
            self.finalizeStoppedSession(isDictation: dict)
        }
    }

    private func resetSessionState() {
        lines = []; finals = []; partials = [:]
        levels = []; levelsThem = []
        notes = MeetingNotes(); notesGenerating = false; notesError = nil
        noteDebounce?.cancel()
        askQuestion = nil; askAnswer = nil; askError = nil; asking = false
        segmentBaseSec = 0
        pendingSegmentAdvance = 0
        currentSessionId = UUID()
        meetingTitle = nil; currentEvent = nil
    }

    /// Pull the current/next calendar event (if calendar access is already granted) to auto-title the
    /// recording + keep its attendees/join-link. Non-blocking; never prompts mid-recording.
    private func fetchCalendarContext() {
        guard calendarEnabled, CalendarService.shared.authorized else { return }
        Task { [weak self] in
            guard let ev = await CalendarService.shared.currentOrNext(), let self else { return }
            if !ev.title.isEmpty { self.meetingTitle = ev.title }
            self.currentEvent = ev
        }
    }

    /// Runs one segment's streams to completion (returns when stop/pause ends them). On failure it
    /// surfaces the error and clears session state — including dictation flags (so the HUD can't stick).
    private func streamSession() async {
        let variant = selectedModel
        let lang = language == "auto" ? nil : language
        let compute = compute
        status = models.isDownloaded(variant) ? .loadingModel : .downloading(0)
        segmentStartedAt = Date()
        DebugLog.log("RECORD stream; model=\(variant) resume=\(segmentBaseSec > 0)")
        do {
            let folder = try await models.ensureDownloaded(variant) { [weak self] fraction in
                if case .downloading = self?.status { self?.status = .downloading(fraction) }
            }
            try await withTimeout(Self.loadTimeout) { [pipeline = self.pipeline] in
                try await pipeline!.prepare(variant: variant, folder: folder, compute: compute)
            }
            modelReady = true
            DebugLog.log("record streaming \(variant)")
            let captureSystem = !dictating && captureMode == .micAndSystem   // dictation is mic-only
            try await pipeline.start(variant: variant, modelFolder: folder, language: lang, compute: compute,
                                     captureSystem: captureSystem, dictation: dictating)
        } catch {
            DebugLog.log("record failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
            isRecording = false
            isPaused = false
            stopping = false
            recordingStartedAt = nil
            if dictating { dictating = false; isDictating = false }   // A4: don't leave the HUD/mic stuck
        }
    }

    func stop() {
        DebugLog.log("RECORD stop pressed; isRecording=\(isRecording)")
        guard isRecording else { return }
        stopping = true
        isPaused = false
        isRecording = false
        status = .idle
        levels = []
        levelsThem = []
        // Do NOT cancel runTask — it must drain the tail flush and then finalize (archive/insert).
        Task { await pipeline.stop() }
    }

    /// Pause capture without ending the session — keeps transcript, notes and timeline.
    /// Resume appends where it left off (widget "Пауза"). Not available during dictation.
    func pause() {
        guard isRecording, !isPaused, !dictating else { return }
        isPaused = true
        // Defer advancing the timeline base to resume(): the tail flush of THIS segment must still
        // resolve against the current base, or it lands out of order.
        if let s = segmentStartedAt { pendingSegmentAdvance = Date().timeIntervalSince(s) }
        segmentStartedAt = nil
        status = .idle
        levels = []
        levelsThem = []
        Task { await pipeline.stop() }   // segment ends; runTask sees !stopping → no finalize
        DebugLog.log("RECORD paused")
    }

    func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        segmentBaseSec += pendingSegmentAdvance   // now the prior tail has been placed on the old base
        pendingSegmentAdvance = 0
        launchRunTask(reset: false)               // new segment; keeps transcript/notes
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Finalize a stopped session once its stream has fully drained.
    private func finalizeStoppedSession(isDictation: Bool) {
        stopping = false
        segmentStartedAt = nil
        if isDictation {
            finishDictation()          // insert + archive dictation, clears dictating/isDictating
        } else {
            archiveMeeting()
        }
        recordingStartedAt = nil
        status = .idle
    }

    private func archiveMeeting() {
        guard !finals.isEmpty else { return }
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let title = meetingTitle ?? notes.topics.first ?? notes.summary.first ?? finals.first?.text ?? "Встреча"
        SessionStore.shared.addMeeting(
            id: currentSessionId,
            title: String(title.prefix(80)),
            date: recordingStartedAt ?? Date(),
            durationSec: duration,
            hasSummary: !notes.isEmpty,
            transcript: transcriptText(),
            noteSummary: notes.summary.isEmpty ? nil : notes.summary,
            noteDecisions: notes.decisions.isEmpty ? nil : notes.decisions,
            noteTopics: notes.topics.isEmpty ? nil : notes.topics
        )
    }

    // MARK: - Push-to-talk dictation

    /// Hotkey pressed: start a mic-only session whose text we insert on release.
    func startDictation() {
        guard !isRecording, stage == .ready else {
            DebugLog.log("dictation ignored: recording=\(isRecording) stage=\(stage)")
            return
        }
        DebugLog.log("dictation start")
        dictating = true
        isDictating = true
        start()   // mic-only (the `dictating` flag forces it)
    }

    /// Hotkey released: stop the stream; the flushed final assembles + inserts the text.
    func stopDictation() {
        guard dictating else { return }
        stop()   // → pipeline flush → .final/.ended → finishDictation()
    }

    /// Toggle-mode dictation (Settings → Режим диктовки = Переключать).
    func toggleDictation() { dictating ? stopDictation() : startDictation() }

    /// Assemble everything said during the hold, insert it at the cursor (or clipboard), and log it.
    private func finishDictation() {
        dictating = false
        isDictating = false

        var text = finals.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
        if let p = partials[.me], !p.text.isEmpty {
            text += (text.isEmpty ? "" : " ") + p.text
        }
        partials[.me] = nil
        text = GlossaryStore.shared.correct(cleanDictation(text))
        guard !text.isEmpty else { DebugLog.log("dictation empty"); return }
        DebugLog.log("dictation final: «\(text)» trigger=\(taskCommand(text) != nil)")

        // Voice command? «открой почту» → run the matching registered command instead of inserting.
        // Deterministic + local (no LLM in the hot path), only fires on a command verb + a registry hit.
        if let target = commandTarget(text), let cmd = CommandStore.shared.match(target) {
            DebugLog.log("dictation → command: «\(cmd.phrase)»")
            runCommand(cmd)
            return
        }

        // Possible spoken task command? The LLM decides: a real "создай задачу/напомни мне …" becomes
        // a task; a question or a message that merely contains "напомни" is inserted as normal text.
        let cfg = llmConfig()
        if taskExtractionEnabled, taskCommand(text) != nil {
            if !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
                dictationProcessing = true
                let command = text
                DebugLog.log("dictation task-gate start")
                Task { [weak self] in
                    var item: ActionItem?
                    var errored = false
                    do {
                        item = try await NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key,
                                                       style: cfg.style, glossary: GlossaryStore.shared.promptFragment)
                            .parseTask(command: command, context: command)
                    } catch { errored = true }
                    guard let self else { return }
                    self.dictationProcessing = false
                    // LLM unreachable but explicit "…задачу" → create anyway (don't drop the command).
                    if item == nil, errored, let raw = self.explicitTaskCommand(command) {
                        item = ActionItem(text: GlossaryStore.shared.correct(raw), owner: nil, due: nil)
                    }
                    if let item {            // it IS a task
                        let clean = GlossaryStore.shared.correct(item.text.trimmingCharacters(in: .whitespaces))
                        if !clean.isEmpty, let created = TaskStore.shared.addVoice(clean, sessionId: nil) {
                            TaskStore.shared.edit(created.id) { $0.owner = item.ownerClean; $0.due = item.dueClean }
                        }
                        self.showTaskCreated(clean)
                        DebugLog.log("dictation → task: \(clean)")
                    } else {                 // genuinely not a task → insert as a normal dictation
                        DebugLog.log("dictation task-gate: not a task → insert")
                        self.finishInsert(command)
                    }
                }
                return
            }
            // No LLM to gate → keyword-only best-effort task.
            if let raw = taskCommand(text) {
                let taskText = GlossaryStore.shared.correct(raw)
                _ = TaskStore.shared.addVoice(taskText, sessionId: nil)
                showTaskCreated(taskText)
                DebugLog.log("dictation → task (no-LLM): \(taskText)")
            }
            return
        }

        finishInsert(text)
    }

    /// Insert a finished dictation — with AI cleanup when enabled (offloaded, timeout-guarded), else raw.
    private func finishInsert(_ text: String) {
        let cfg = llmConfig()
        if aiDictationEnabled, !cfg.endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            dictationProcessing = true
            let hint = aiDictationStyle.hint
            let raw = text
            DebugLog.log("dictation AI polish start (\(raw.count) chars, style=\(aiDictationStyle.rawValue))")
            Task { [weak self] in
                let t0 = Date()
                let polished = await Self.polishWithTimeout(raw, cfg: cfg, hint: hint,
                                                            glossary: GlossaryStore.shared.promptFragment)
                guard let self else { return }
                self.dictationProcessing = false
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                DebugLog.log("dictation AI polish done in \(ms)ms (in=\(raw.count) out=\(polished.count) changed=\(polished != raw))")
                self.insertDictation(GlossaryStore.shared.correct(polished))
            }
            return
        }
        DebugLog.log("dictation no-AI path (enabled=\(aiDictationEnabled), endpoint=\(cfg.endpoint.isEmpty ? "empty" : "set"))")
        insertDictation(text)
    }

    /// Paste (or copy-card), archive, and count. Shared by the raw and AI-polished dictation paths.
    private func insertDictation(_ text: String) {
        let autopaste = TextInserter.insert(text)
        addDictation(text)
        SessionStore.shared.addDictation(text: text, date: Date())
        totalDictatedWords += Self.wordCount(text)
        if !autopaste { showDictationCard(text) }   // no editable field → the copy card
        DebugLog.log("dictation done (\(text.count) chars, autopaste=\(autopaste))")
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// Run the LLM polish with a hard timeout; returns the polished text, or the raw text if the
    /// model errors or is too slow (dictation must feel instant, never hang on a slow endpoint).
    private static func polishWithTimeout(_ text: String, cfg: LLMConfig,
                                          hint: String, glossary: String?) async -> String {
        let gen = NoteGenerator(endpoint: cfg.endpoint, model: cfg.model, apiKey: cfg.key, style: cfg.style, glossary: glossary)
        return await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { return try await gen.polishDictation(text, styleHint: hint) }
                catch { DebugLog.log("dictation AI polish ERROR: \(error) → fallback raw"); return text }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Task.isCancelled { return text }
                DebugLog.log("dictation AI polish TIMEOUT (>6s) → fallback raw")
                return text
            }
            let first = await group.next() ?? text
            group.cancelAll()
            return first
        }
    }

    /// Light cleanup for dictated text: trim, collapse spaces, capitalize the first letter.
    private func cleanDictation(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = RussianNumbers.digitsify(t)   // «сто пятьдесят» → «150», local + instant, no LLM needed
        if let f = t.first { t = f.uppercased() + t.dropFirst() }
        return t
    }

    private func showDictationCard(_ text: String) {
        dictationCardIsTask = false
        dictationCardIsCommand = false
        dictationCard = text
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { self?.dictationCard = nil }
        }
    }

    private func showTaskCreated(_ text: String) {
        dictationCardIsTask = true
        dictationCardIsCommand = false
        dictationCard = text
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.dictationCard = nil }
        }
    }

    // MARK: - Voice commands

    /// Run a matched command — immediately for safe/idempotent actions, or show a tap-to-confirm
    /// card first for anything the user flagged as needing confirmation (VPN, scripts, …).
    private func runCommand(_ cmd: CommandItem) {
        if cmd.needsConfirm {
            pendingCommand = cmd
            dictationCardIsTask = false
            dictationCardIsCommand = true
            dictationCard = cmd.phrase.isEmpty ? cmd.value : cmd.phrase
            cardTask?.cancel()
            cardTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)   // decision window
                if !Task.isCancelled { self?.pendingCommand = nil; self?.dictationCard = nil; self?.dictationCardIsCommand = false }
            }
        } else {
            showCommandToast(CommandStore.shared.run(cmd))
        }
    }

    /// Tapped "Выполнить" on the confirm card.
    func confirmPendingCommand() {
        guard let cmd = pendingCommand else { return }
        pendingCommand = nil
        showCommandToast(CommandStore.shared.run(cmd))
    }

    private func showCommandToast(_ label: String) {
        dictationCardIsTask = false
        dictationCardIsCommand = true
        dictationCard = label
        cardTask?.cancel()
        cardTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.dictationCard = nil; self?.dictationCardIsCommand = false }
        }
    }

    func dismissDictationCard() {
        cardTask?.cancel(); dictationCard = nil; pendingCommand = nil; dictationCardIsCommand = false
    }

    private func addDictation(_ text: String) {
        dictationHistory.insert(DictationEntry(text: text, date: Date()), at: 0)
        if dictationHistory.count > Self.historyLimit {
            dictationHistory.removeLast(dictationHistory.count - Self.historyLimit)
        }
        saveHistory()
    }

    func clearDictationHistory() {
        dictationHistory = []
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let items = try? JSONDecoder().decode([DictationEntry].self, from: data) else { return }
        dictationHistory = items
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(dictationHistory) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    // MARK: - Helpers

    private func beginPreparing() {
        preparing = true
        prepareError = nil
        preparingStartedAt = Date()
    }

    private func failPreparing(_ message: String) {
        preparing = false
        prepareError = message
    }

    private func onModelChanged() {
        modelReady = false
        prepareError = nil
        prepareTask?.cancel()
        prepareActiveModelIfDownloaded()
    }

    private func onComputeChanged() {
        modelReady = false
        prepareError = nil
        prepareTask?.cancel()
        Task { [weak self] in
            await self?.pipeline.evictAll()
            self?.prepareActiveModelIfDownloaded()
        }
    }

    private func applyStatus(_ status: PipelineStatus) {
        guard isRecording || status == .idle else { return }
        self.status = status
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(selectedModel, forKey: "selectedModel")
        d.set(language, forKey: "language")
        d.set(llmEndpoint, forKey: "llmEndpoint")
        d.set(llmModel, forKey: "llmModel")
    }

    private func persistCompute() {
        UserDefaults.standard.set(compute.rawValue, forKey: "compute")
    }
}

/// One dictated snippet, kept in history (Wispr Flow style).
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
}
