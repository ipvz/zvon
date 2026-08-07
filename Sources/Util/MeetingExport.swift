import AppKit
import CoreText

/// Turns a meeting recap into shareable artifacts: clean structured text (for messengers / copy)
/// and a premium branded PDF (vector text, paginated) for formal sharing.
struct MeetingExport {
    var title: String
    var date: Date
    var durationSec: Double?
    var participants: [String]
    var summary: [String]
    var decisions: [String]
    var tasks: [TaskLine]
    var transcript: [Turn]
    var includeTranscript: Bool
    /// When this artifact was produced — a protocol has to say when it was written, separately
    /// from when the meeting happened.
    var generatedAt: Date = Date()

    struct TaskLine { var text: String; var owner: String?; var due: String?; var done: Bool }
    /// `stamp` is the wall-clock time the turn was spoken ("14:32:05"), nil for older records
    /// saved before turn times were persisted.
    struct Turn { var role: String; var text: String; var stamp: String? = nil }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy, HH:mm"; return f
    }()
    private var meta: String {
        var p = [Self.dateFmt.string(from: date)]
        if let d = durationSec, d > 0 { p.append("\(Int((d / 60).rounded())) мин") }
        if !participants.isEmpty { p.append("\(participants.count) уч.") }
        return p.joined(separator: " · ")
    }
    /// Meeting window as a range — "14:30 – 15:12" — so the reader sees start AND end, not just start.
    private static let clockFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private var window: String? {
        guard let d = durationSec, d > 0 else { return nil }
        return "\(Self.clockFmt.string(from: date)) – \(Self.clockFmt.string(from: date.addingTimeInterval(d)))"
    }
    private var generatedLine: String { "Протокол сформирован: " + Self.dateFmt.string(from: generatedAt) }
    private func turnLine(_ t: Turn) -> String {
        let head = [t.stamp, t.role.isEmpty ? nil : t.role].compactMap { $0 }.joined(separator: " ")
        return head.isEmpty ? t.text : "\(head): \(t.text)"
    }
    private func taskMeta(_ t: TaskLine) -> String {
        [t.owner, t.due].compactMap { $0 }.filter { !$0.isEmpty && $0.lowercased() != "null" }.joined(separator: " · ")
    }

    /// Chronological transcript, one turn per line, each carrying the time it was spoken. This is
    /// what a timeline-aware artifact (protocol, minutes) needs as raw input — without it the model
    /// has nothing to build a timeline from and can only guess an order.
    func timedTranscript() -> String { transcript.map(turnLine).joined(separator: "\n") }

    // MARK: - Plain structured text (Telegram / Slack / copy — renders everywhere)

    func shareText() -> String {
        var out = [title, meta]
        if let w = window { out.append("Время встречи: " + w) }
        out.append(generatedLine)
        out.append("")
        func sec(_ h: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out.append(h.uppercased()); out.append(contentsOf: items.map { "• \($0)" }); out.append("")
        }
        sec("Итог", summary)
        sec("Решения", decisions)
        if !tasks.isEmpty {
            out.append("ЗАДАЧИ")
            for t in tasks {
                let m = taskMeta(t)
                out.append("\(t.done ? "☑" : "☐") \(t.text)" + (m.isEmpty ? "" : "  (\(m))"))
            }
            out.append("")
        }
        if includeTranscript, !transcript.isEmpty {
            out.append("РАСШИФРОВКА")
            out.append(contentsOf: transcript.map(turnLine)); out.append("")
        }
        out.append("— ZVON")
        return out.joined(separator: "\n")
    }

    func markdown() -> String {
        var out = ["# \(title)", "", "*\(meta)*"]
        if let w = window { out.append("*Время встречи: \(w)*") }
        out.append("*\(generatedLine)*")
        out.append("")
        func sec(_ h: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out.append("## \(h)"); out.append(contentsOf: items.map { "- \($0)" }); out.append("")
        }
        sec("Итог", summary)
        sec("Решения", decisions)
        if !tasks.isEmpty {
            out.append("## Задачи")
            for t in tasks {
                let m = taskMeta(t)
                out.append("- [\(t.done ? "x" : " ")] \(t.text)" + (m.isEmpty ? "" : " (\(m))"))
            }
            out.append("")
        }
        if includeTranscript, !transcript.isEmpty {
            out.append("## Расшифровка")
            out.append(contentsOf: transcript.map { t in
                let stamp = t.stamp.map { "`\($0)` " } ?? ""
                return "\(stamp)**\(t.role):** \(t.text)"
            })
            out.append("")
        }
        out.append("---"); out.append("*ZVON*")
        return out.joined(separator: "\n")
    }

    // MARK: - PDF (vector, paginated, branded)

    private enum Ink {
        static let text = NSColor(srgbRed: 0x23/255, green: 0x21/255, blue: 0x20/255, alpha: 1)
        static let gray = NSColor(srgbRed: 0x6A/255, green: 0x66/255, blue: 0x5E/255, alpha: 1)
        static let accent = NSColor(srgbRed: 0x00/255, green: 0x7D/255, blue: 0x7E/255, alpha: 1)
        static let rule = NSColor(srgbRed: 0xE5/255, green: 0xE1/255, blue: 0xD9/255, alpha: 1)
    }

    private func attributed() -> NSAttributedString {
        let s = NSMutableAttributedString()
        func para(_ before: CGFloat, _ after: CGFloat, _ lh: CGFloat = 1.25, head: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before; p.paragraphSpacing = after; p.lineHeightMultiple = lh
            if head > 0 { p.headIndent = head; p.firstLineHeadIndent = 0 }
            return p
        }
        func add(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                 kern: CGFloat = 0, style: NSParagraphStyle) {
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .kern: kern, .paragraphStyle: style,
            ]))
        }
        add(title, size: 24, weight: .semibold, color: Ink.text, style: para(0, 2))
        add(meta, size: 11, weight: .regular, color: Ink.gray, style: para(0, 2))
        if let w = window { add("Время встречи: " + w, size: 11, weight: .regular, color: Ink.gray, style: para(0, 2)) }
        add(generatedLine, size: 11, weight: .regular, color: Ink.gray, style: para(0, 14))

        func section(_ header: String, _ bullets: [String]) {
            guard !bullets.isEmpty else { return }
            add(header.uppercased(), size: 11, weight: .semibold, color: Ink.accent, kern: 0.8, style: para(14, 8))
            for b in bullets {
                add("•  " + b, size: 12.5, weight: .regular, color: Ink.text, style: para(0, 6, 1.3, head: 14))
            }
        }
        section("Итог", summary)
        section("Решения", decisions)
        if !tasks.isEmpty {
            add("ЗАДАЧИ", size: 11, weight: .semibold, color: Ink.accent, kern: 0.8, style: para(14, 8))
            for t in tasks {
                let m = taskMeta(t)
                let line = "\(t.done ? "☑" : "☐")  \(t.text)" + (m.isEmpty ? "" : "   — \(m)")
                add(line, size: 12.5, weight: .regular, color: t.done ? Ink.gray : Ink.text, style: para(0, 6, 1.3, head: 20))
            }
        }
        if includeTranscript, !transcript.isEmpty {
            add("РАСШИФРОВКА", size: 11, weight: .semibold, color: Ink.accent, kern: 0.8, style: para(16, 8))
            for t in transcript {
                let head = [t.stamp, t.role].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
                let a = NSMutableAttributedString(string: head + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Ink.gray,
                    .paragraphStyle: para(0, 5, 1.3),
                ])
                a.append(NSAttributedString(string: t.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .regular), .foregroundColor: Ink.text,
                    .paragraphStyle: para(0, 5, 1.3),
                ]))
                s.append(a)
            }
        }
        add("ZVON", size: 9.5, weight: .medium, color: Ink.gray, kern: 0.5, style: para(20, 0))
        return s
    }

    func pdfData() -> Data {
        let attr = attributed()
        let pageW: CGFloat = 595.2, pageH: CGFloat = 841.8, margin: CGFloat = 54   // A4
        var media = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let column = CGRect(x: margin, y: margin, width: pageW - 2 * margin, height: pageH - 2 * margin)
        let path = CGPath(rect: column, transform: nil)
        var start = 0
        let total = attr.length
        while start < total {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }   // nothing more fits → avoid an infinite loop
            start += visible.length
        }
        ctx.closePDF()
        return out as Data
    }

    /// Write the PDF to a temp file (for the share sheet / AirDrop / Mail attachment).
    func pdfTempURL() -> URL? {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Итог" : safe).pdf")
        do { try pdfData().write(to: url); return url } catch { return nil }
    }
}
