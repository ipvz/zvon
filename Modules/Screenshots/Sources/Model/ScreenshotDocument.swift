import AppKit
import Combine

@MainActor
final class ScreenshotDocument: ObservableObject {
    let source: CGImage
    let renderer = ScreenshotRenderer()
    @Published private(set) var annotations: [ScreenshotAnnotation] = []
    @Published private(set) var preview: CGImage
    @Published private(set) var rendering = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var selectedID: UUID?
    @Published var tool: ScreenshotTool = .arrow
    @Published var style = AnnotationStyle()
    @Published var error: String?
    @Published var textDraft: ScreenshotAnnotation? {
        didSet { if oldValue?.id != textDraft?.id { scheduleRender() } }
    }
    @Published var status = ""
    @Published var cropRect: CGRect?
    @Published var adjustingCrop = true
    @Published var exporting = false
    private var undoStack: [[ScreenshotAnnotation]] = []
    private var redoStack: [[ScreenshotAnnotation]] = []
    private var transaction: [ScreenshotAnnotation]?
    private var renderTask: Task<Void, Never>?
    private var revision = 0
    private var closed = false
    private var effectPrefix: [ScreenshotAnnotation] = []
    @Published private var effectBase: CGImage?
    private var styles: [ScreenshotTool: AnnotationStyle] = [:]
    private(set) var pixelScale: CGFloat = 1

    /// Vectors after the last image effect draw directly at display refresh rate. A cached raster
    /// prefix preserves stacking order (including effects over earlier vectors).
    var presentation: (image: CGImage, vectors: [ScreenshotAnnotation]) {
        let visible = visibleAnnotations
        guard let index = visible.lastIndex(where: { $0.tool.isEffect }) else { return (source, visible) }
        let prefix = Array(visible[...index])
        if prefix == effectPrefix, let effectBase { return (effectBase, Array(visible.dropFirst(index + 1))) }
        return (preview, [])
    }
    private var visibleAnnotations: [ScreenshotAnnotation] { annotations.filter { $0.id != textDraft?.id } }
    private var canPresentLive: Bool {
        let visible = visibleAnnotations
        guard let index = visible.lastIndex(where: { $0.tool.isEffect }) else { return true }
        return effectBase != nil && Array(visible[...index]) == effectPrefix
    }

    func configureScale(_ scale: CGFloat) {
        pixelScale = max(1, scale)
        for tool in ScreenshotTool.allCases {
            var value = AnnotationStyle()
            value.lineWidth = 3 * pixelScale; value.fontSize = 20 * pixelScale; value.effectStrength = 12 * pixelScale
            if tool == .marker { value.color = AnnotationColor(.systemYellow); value.lineWidth = 5 * pixelScale }
            if tool == .text { value.color = AnnotationColor(.systemRed) }
            if tool == .redact { value.color = AnnotationColor(.black) }
            styles[tool] = value
        }
        style = styles[tool] ?? style
    }
    func chooseTool(_ tool: ScreenshotTool) {
        adjustingCrop = false; selectedID = nil; self.tool = tool
        style = styles[tool] ?? AnnotationStyle()
    }
    var size: CGSize { CGSize(width: source.width, height: source.height) }
    var selected: ScreenshotAnnotation? { annotations.first { $0.id == selectedID } }

    init(source: CGImage) { self.source = source; preview = source }
    deinit { renderTask?.cancel() }

    func beginEdit() { if transaction == nil { transaction = annotations } }
    func replace(_ annotation: ScreenshotAnnotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) { annotations[index] = annotation }
        else { annotations.append(annotation) }
        selectedID = annotation.id
        if style != annotation.style { style = annotation.style }
        scheduleRender()
    }
    func commitEdit() {
        guard let before = transaction else { return }
        transaction = nil
        guard before != annotations else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
        redoStack.removeAll()
        updateHistory()
        scheduleRender()
    }
    func cancelEdit() {
        guard let before = transaction else { return }
        annotations = before; transaction = nil; scheduleRender()
    }
    func add(_ annotation: ScreenshotAnnotation) { beginEdit(); replace(annotation); commitEdit() }
    func deleteSelection() {
        guard let id = selectedID else { return }
        beginEdit(); annotations.removeAll { $0.id == id }; selectedID = nil; commitEdit(); scheduleRender()
    }
    func undo() {
        cancelEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations); annotations = previous; selectedID = nil
        updateHistory(); scheduleRender()
    }
    func redo() {
        cancelEdit()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations); annotations = next; selectedID = nil
        updateHistory(); scheduleRender()
    }
    func updateStyle(_ next: AnnotationStyle) {
        style = next
        styles[textDraft?.tool ?? selected?.tool ?? tool] = next
        if var draft = textDraft { draft.style = next; textDraft = draft; return }
        guard var annotation = selected else { return }
        let ownsTransaction = transaction == nil
        beginEdit()
        let previousFontSize = annotation.style.fontSize
        annotation.style = next
        if annotation.tool == .text, previousFontSize != next.fontSize {
            let crop = cropRect ?? CGRect(origin: .zero, size: size)
            annotation = annotation.fittingText(maxWidth: min(crop.maxX - annotation.bounds.minX,
                annotation.bounds.width * next.fontSize / previousFontSize), maxHeight: crop.maxY - annotation.bounds.minY)
        }
        replace(annotation)
        if ownsTransaction { commitEdit() }
    }
    func applyText(_ annotation: ScreenshotAnnotation) {
        let result = annotation.fittingText(maxWidth: annotation.bounds.width,
            maxHeight: (cropRect?.maxY ?? size.height) - annotation.bounds.minY)
        add(result); style = result.style; tool = .select; textDraft = nil
    }
    func select(_ id: UUID?) {
        selectedID = id
        if let selected { style = selected.style }
    }
    func flattened() async throws -> CGImage {
        // Snapshot on the main actor: never export a partially rendered preview.
        let snapshot = annotations
        let crop = cropRect
        let rendered = try await renderer.render(source: source, annotations: snapshot)
        guard let crop else { return rendered }
        guard let image = rendered.cropping(to: crop) else { throw ScreenshotError.emptySelection }
        return image
    }
    func close() { closed = true; renderTask?.cancel(); renderTask = nil; revision += 1; effectBase = nil; effectPrefix = [] }

    private func updateHistory() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
    private func scheduleRender() {
        guard !closed else { return }
        revision += 1; status = ""
        // Pure vector drags need no full-screen bitmap allocations. Rasterize on commit;
        // only edits that affect an image-effect prefix need raster work during the gesture.
        if transaction != nil && canPresentLive { return }
        rendering = true
        // One worker consumes the newest snapshot. Continuous mouse events never postpone
        // rendering indefinitely, and never enqueue a render for every event.
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            defer { renderTask = nil; rendering = false }
            do {
                while !Task.isCancelled {
                    let expected = revision, snapshot = visibleAnnotations
                    let split = snapshot.lastIndex(where: { $0.tool.isEffect }).map { $0 + 1 } ?? 0
                    let prefix = Array(snapshot.prefix(split)), suffix = Array(snapshot.dropFirst(split))
                    let base: CGImage
                    if prefix.isEmpty { base = source }
                    else if prefix == effectPrefix, let cached = effectBase { base = cached }
                    else {
                        base = try await renderer.render(source: source, annotations: prefix)
                        try Task.checkCancellation()
                        effectPrefix = prefix; effectBase = base
                    }
                    let result = try await renderer.render(source: base, annotations: suffix)
                    try Task.checkCancellation()
                    preview = result
                    if revision == expected || (transaction != nil && canPresentLive) { return }
                    await Task.yield()
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
