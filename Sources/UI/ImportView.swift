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
                    if importer.isRunning { runningCard }
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

    @ViewBuilder private var historySection: some View {
        let records = importer.importedRecords()
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Импортированные", "Imported")).font(PFont.label).tracking(0.4)
                .foregroundStyle(Color.pInk3)
            if records.isEmpty {
                Text(L("Пока пусто. Импортированные файлы появятся здесь и в «Записях».",
                       "Nothing yet. Imported files show up here and in Records."))
                    .font(.system(size: 12.5)).foregroundStyle(Color.pInk3)
            } else {
                VStack(spacing: 1) {
                    ForEach(records) { r in row(r) }
                }
            }
        }
    }

    private func row(_ r: SessionRecord) -> some View {
        Button { onOpen(r.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Color.pInk3).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(PFont.secondary).foregroundStyle(Color.pInk1).lineLimit(1)
                    Text(r.subtitle).font(.system(size: 11)).foregroundStyle(Color.pInk3)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.pInk3)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.pCard))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.pLine2, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
