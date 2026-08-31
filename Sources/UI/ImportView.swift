import SwiftUI
import UniformTypeIdentifiers

/// Turn a recording made elsewhere into a record: a call someone else captured, a webinar, a voice
/// memo. A destination rather than a button that opens a file panel on click — there is history
/// here worth coming back to, and a screen that only fires a dialog gives you nowhere to land.
struct ImportView: View {
    var onOpen: (UUID) -> Void

    @ObservedObject private var importer = FileTranscriber.shared
    @ObservedObject private var store = TranscriptStore.shared
    @ObservedObject private var sessions = SessionStore.shared
    @ObservedObject private var loc = L11n.shared
    @State private var dropTargeted = false

    /// The most recent successful import, while it is still the newest thing in the log — a plain
    /// "here is what came out, open it" instead of throwing the user into another pane.
    private var justFinished: SessionRecord? {
        guard let first = importer.log.first, first.failure == nil else { return nil }
        return importer.record(for: first)
    }

    private var busyReason: String? {
        if store.isRecording { return L("Идёт запись — модель занята", "Recording in progress — the model is busy") }
        if store.isDictating { return L("Идёт диктовка — модель занята", "Dictation in progress — the model is busy") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline(color: .pLine2)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    dropZone
                    if importer.isRunning { runningCard } else if let done = justFinished { doneCard(done) }
                    historySection
                }
                .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 28)
                .frame(maxWidth: PMetric.notesMeasure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.pCanvas)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Импорт", "Import")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.pInk1)
                Text(L("Расшифровка аудио и видео — на этом Mac",
                       "Transcribe audio and video — on this Mac"))
                    .font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20).frame(height: 56)
        .background(Color.pCanvas)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 22)).foregroundStyle(dropTargeted ? Color.pAccent : Color.pInk3)
            Text(L("Перетащите файл сюда", "Drop a file here"))
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Color.pInk1)
            Text(L("Аудио или видео — mp4, mov, m4a, mp3, wav, webm, mkv",
                   "Audio or video — mp4, mov, m4a, mp3, wav, webm, mkv"))
                .font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
            Button(L("Выбрать файл…", "Choose a file…")) {
                importer.pickAndTranscribe(language: store.language)
            }
            .buttonStyle(PPrimaryButtonStyle())
            .disabled(!importer.canStart)
            .padding(.top, 4)
            if let busyReason {
                Text(busyReason).font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.pAccentWash : Color.pCard))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.pAccent : Color.pLine,
                              style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [] : [5, 4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard importer.canStart, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in importer.transcribe(url, language: store.language) }
            }
            return true
        }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var runningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(importer.stage ?? L("Работаю…", "Working…"))
                    .font(.system(size: 13)).foregroundStyle(Color.pInk1)
                Spacer(minLength: 8)
                Text("\(Int(importer.progress * 100))%")
                    .font(PFont.monoSecondary).foregroundStyle(Color.pInk3).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.pLine).frame(height: 4)
                    Capsule().fill(Color.pAccent).frame(width: g.size.width * importer.progress, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(14)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pLine, lineWidth: 1))
    }

    private func doneCard(_ record: SessionRecord) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color.pAccent.opacity(0.16)).frame(width: 28, height: 28)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.pAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Готово: \(record.title)", "Done: \(record.title)"))
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.pInk1).lineLimit(1)
                Text(L("Расшифровка в «Записях». Итог не собирается сам — соберите документ по рецепту, если нужен.",
                       "The transcript is in Records. No summary is generated automatically — build one from a recipe if you want it."))
                    .font(.system(size: 11.5)).foregroundStyle(Color.pInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("Открыть", "Open")) { onOpen(record.id) }
                .buttonStyle(PPrimaryButtonStyle())
        }
        .padding(14)
        .background(Color.pCard).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pAccent.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("История", "History")).font(PFont.label).tracking(0.4).foregroundStyle(Color.pInk3)
                Spacer()
                if !importer.log.isEmpty {
                    Button(L("Очистить", "Clear")) { importer.clearLog() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.pInk3)
                        .help(L("Убрать записи журнала — сами расшифровки останутся",
                                "Clear the log — the transcripts themselves stay"))
                }
            }
            if importer.log.isEmpty {
                Text(L("Пока пусто. Расшифрованные файлы появятся здесь и в «Записях».",
                       "Nothing yet. Transcribed files show up here and in Records."))
                    .font(.system(size: 12.5)).foregroundStyle(Color.pInk3)
            } else {
                VStack(spacing: 6) {
                    ForEach(importer.log) { entry in row(entry) }
                }
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM, HH:mm"; return f
    }()

    private func hms(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d ч %02d мин", s / 3600, (s % 3600) / 60)
                         : String(format: "%d мин %02d с", s / 60, s % 60)
    }

    private func row(_ entry: FileTranscriber.Entry) -> some View {
        let record = importer.record(for: entry)
        let gone = entry.failure == nil && record == nil
        return Button {
            if let record { onOpen(record.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.failure == nil ? (gone ? "trash" : "waveform") : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.failure == nil ? (gone ? Color.pInk3 : Color.pAccent) : Color.pDanger)
                    .frame(width: 16).padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.fileName).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                    if let failure = entry.failure {
                        Text(failure).font(.system(size: 11.5)).foregroundStyle(Color.pDanger)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        // The three numbers worth keeping: when, how long the audio was, and how
                        // long the machine took to get through it.
                        Text([Self.stamp.string(from: entry.importedAt),
                              hms(entry.audioSec),
                              String(format: L("за %.0f с · %.0f× быстрее реального времени",
                                               "in %.0fs · %.0f× realtime"), entry.elapsedSec, entry.speedup)]
                                .joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(Color.pInk3).lineLimit(1)
                    }
                    if gone {
                        Text(L("Запись удалена из библиотеки", "Record deleted from the library"))
                            .font(.system(size: 11)).foregroundStyle(Color.pInk3)
                    }
                }
                Spacer(minLength: 0)
                if record != nil {
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.pInk3).padding(.top, 2)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.pCard))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
    }
}
