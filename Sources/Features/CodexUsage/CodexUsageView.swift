import AppKit
import SwiftUI

/// Monochrome terminal mark from the Codex icon, drawn as vectors for crisp menu-bar rendering.
@MainActor
enum CodexUsageGlyph {
    static func image(size: CGFloat = 16, color: NSColor = .labelColor) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: false) { _ in
            let p = NSBezierPath()
            p.move(to: CGPoint(x: size * 0.13, y: size * 0.78))
            p.line(to: CGPoint(x: size * 0.39, y: size * 0.5))
            p.line(to: CGPoint(x: size * 0.13, y: size * 0.22))
            p.move(to: CGPoint(x: size * 0.52, y: size * 0.22))
            p.line(to: CGPoint(x: size * 0.9, y: size * 0.22))
            p.lineCapStyle = .round; p.lineJoinStyle = .round; p.lineWidth = size * 0.13
            color.setStroke(); p.stroke()
            return true
        }
    }
    static func append(to base: NSImage, remaining: Int?, dark: Bool) -> (image: NSImage, boundary: CGFloat) {
        let ink = NSColor(white: dark ? 0.9 : 0.16, alpha: 1)
        let text = remaining.map { "\($0)%" } ?? "—"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let boundary = base.size.width + 4
        let width = max(29, textSize.width)
        let image = NSImage(size: CGSize(width: boundary + 1 + 7 + 16 + 5 + width + 2, height: 22), flipped: false) { _ in
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            ink.withAlphaComponent(0.3).setFill(); CGRect(x: boundary, y: 5, width: 1, height: 12).fill()
            Self.image(color: ink).draw(in: CGRect(x: boundary + 8, y: 3, width: 16, height: 16))
            var attributes = attrs
            if let remaining, remaining <= 10 { attributes[.foregroundColor] = NSColor.systemOrange }
            (text as NSString).draw(at: CGPoint(x: boundary + 29, y: (22 - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return (image, boundary)
    }
}

struct CodexUsagePopover: View {
    @ObservedObject var store: CodexUsageStore
    @ObservedObject private var loc = L11n.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                Image(nsImage: CodexUsageGlyph.image(size: 22, color: .black)).renderingMode(.template)
                    .foregroundStyle(.primary).frame(width: 24, height: 24)
                Text("Codex").font(.system(size: 16, weight: .semibold))
                Spacer()
                if let plan = store.snapshot?.bucket.planType, plan != "unknown" {
                    Text(plan.capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
            }
            if let snapshot = store.snapshot, !snapshot.bucket.windows.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(snapshot.bucket.windows.enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.period).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(L("осталось", "remaining")).font(.system(size: 10)).foregroundStyle(.secondary)
                                Text("\(window.remainingPercent)%").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            GeometryReader { proxy in
                                Capsule().fill(.primary.opacity(0.08))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(window.remainingPercent <= 10 ? Color.orange : Color.teal)
                                            .frame(width: proxy.size.width * Double(window.remainingPercent) / 100)
                                    }
                            }.frame(height: 5)
                            if let reset = window.resetDate {
                                HStack(spacing: 4) {
                                    Text(L("Обновится", "Resets"))
                                    Text(reset, format: .dateTime.day().month(.abbreviated).hour().minute())
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.opacity(store.error == nil && !snapshot.isStale(at: Date()) ? 1 : 0.55)
                if snapshot.bucket.windows.count > 1 {
                    Text(L("В строке меню — меньший остаток.", "The menu bar shows the lower remaining allowance."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else if store.error == nil {
                Text(store.isRefreshing ? L("Получаем лимиты…", "Fetching limits…") : L("Codex не предоставил процентный лимит.", "Codex did not provide a percentage limit."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(error.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.snapshot?.isStale(at: Date()) == true {
                Text(L("Данные устарели · обновляем", "Data is out of date · refreshing")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if let date = store.snapshot?.fetchedAt {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help(L("Последнее успешное обновление", "Last successful refresh"))
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }.buttonStyle(.plain).disabled(store.isRefreshing)
                    .accessibilityLabel(L("Обновить лимиты Codex", "Refresh Codex usage"))
                    .help(L("Обновить", "Refresh"))
                Button(L("Открыть Codex", "Open Codex")) { Self.openCodex() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).padding(.leading, 10)
            }
        }
        .padding(20).frame(width: 300)
    }
    private static func openCodex() {
        for path in ["/Applications/Codex.app", "/Applications/ChatGPT.app"] where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path)); return
        }
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
    }
}
