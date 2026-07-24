import Foundation

/// Floating-widget size (the NSPanel morphs between these).
enum WidgetSize: Sendable { case puck, compact, expanded }

/// Who is speaking. Source-based roles: the microphone is the local user, the system-audio
/// loopback is everyone else on the call. Zero ML — 100% accurate for the 2-party split.
enum Speaker: String, Sendable, Codable {
    case me
    case them
    var title: String { self == .me ? "Вы" : "Собеседник" }
}

/// One line in the roled transcript timeline.
struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id: UInt64
    var speaker: Speaker
    var text: String
    var isFinal: Bool
    var startSec: Double   // seconds since recording start (for chronological ordering)
}

/// What a single-stream `UtteranceTranscriber` emits. The pipeline tags each with a `Speaker`.
enum TranscriptionEvent: Sendable {
    case final(text: String, startSec: Double)
    case interim(String)
    case meter([Float])
    case ended
}

/// Snapshot of the live transcription pushed from the speech pipeline to the UI.
struct StreamSnapshot: Sendable {
    /// Text the model has committed and will not rewrite.
    var confirmed: String
    /// In-progress tail that may still change.
    var pending: String
    /// Recent input energy (for the level meter).
    var energy: [Float]
    var isRecording: Bool
}

/// Coarse pipeline state during an active recording session.
enum PipelineStatus: Sendable, Equatable {
    case idle
    case downloading(Double)   // 0…1, model files being fetched
    case loadingModel          // compiling/loading CoreML into memory
    case listening
    case error(String)
}

/// What to record. Mic = the local speaker; system audio = everyone else on the call
/// (loopback), captured locally with no bot joining the meeting.
enum CaptureMode: String, CaseIterable, Sendable {
    case micOnly
    case micAndSystem

    var title: String {
        switch self {
        case .micOnly: return "Только микрофон"
        case .micAndSystem: return "Микрофон + динамик"
        }
    }

    var note: String {
        switch self {
        case .micOnly: return "Ваша речь. Подходит для диктовки и личных заметок."
        case .micAndSystem: return "Ваш микрофон + звук собеседников из динамика — для созвонов."
        }
    }
}

/// Which hardware CoreML uses. Apple Silicon advantage: the Neural Engine is most efficient
/// at runtime but pays a one-time compile cost; GPU starts faster.
enum ComputePreference: String, CaseIterable, Sendable {
    case neuralEngine
    case gpu

    var title: String {
        switch self {
        case .neuralEngine: return "Нейромодуль (ANE)"
        case .gpu: return "GPU (Metal)"
        }
    }

    var note: String {
        switch self {
        case .neuralEngine: return "Эффективнее в работе, дольше первая подготовка (разово)"
        case .gpu: return "Быстрый старт, чуть выше энергопотребление"
        }
    }
}

/// High-level stage the main window renders. Derived by the store from all sub-states.
enum AppStage: Equatable {
    case needsModel
    case downloading(Double)
    case preparing
    case ready
    case listening
    case error(String)
}

/// User-facing errors from the speech pipeline.
enum GranulaError: LocalizedError {
    case modelLoad(String)

    var errorDescription: String? {
        switch self {
        case .modelLoad(let message): return message
        }
    }
}
