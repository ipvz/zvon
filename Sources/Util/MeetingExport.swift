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

    struct TaskLine { var text: String; var owner: String?; var due: String?; var done: Bool }
    struct Turn { var role: String; var text: String }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM yyyy, HH:mm"; return f
    }()
    private var meta: String {
        var p = [Self.dateFmt.string(from: date)]
        if let d = durationSec, d > 0 { p.append("\(Int((d / 60).rounded())) мин") }
        if !participants.isEmpty { p.append("\(participants.count) уч.") }
        return p.joined(separator: " · ")
    }
    private func taskMeta(_ t: TaskLine) -> String {
        [t.owner, t.due].compactMap { $0 }.filter { !$0.isEmpty && $0.lowercased() != "null" }.joined(separator: " · ")
    }

    // MARK: - Plain structured text (Telegram / Slack / copy — renders everywhere)

    func shareText() -> String {
        var out = [title, meta, ""]
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
            out.append(contentsOf: transcript.map { "\($0.role): \($0.text)" }); out.append("")
        }
        out.append("— ZVON")
        return out.joined(separator: "\n")
    }

    func markdown() -> String {
        var out = ["# \(title)", "", "*\(meta)*", ""]
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
            out.append("## Расшифровка"); out.append(contentsOf: transcript.map { "**\($0.role):** \($0.text)" }); out.append("")
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
        add(meta, size: 11, weight: .regular, color: Ink.gray, style: para(0, 14))

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
                let a = NSMutableAttributedString(string: t.role + "  ", attributes: [
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
