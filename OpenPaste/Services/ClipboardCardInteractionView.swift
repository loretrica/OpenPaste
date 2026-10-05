import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardDragTypes {
    static let internalItemsType = NSPasteboard.PasteboardType("it.lore-trica.openpaste.items")
}

enum ClipboardPasteboardItemWriter {
    static func write(_ payload: ClipboardPayload, to item: NSPasteboardItem, plainText: Bool) {
        guard !plainText else {
            item.setString(payload.content, forType: .string)
            return
        }

        for representation in payload.representations {
            item.setData(
                representation.data,
                forType: NSPasteboard.PasteboardType(representation.type))
        }
        if let firstFile = payload.files.first,
           let url = firstFile.resolvedURL() {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        if payload.kind == .link,
           let url = URL(string: payload.content) {
            item.setString(url.absoluteString, forType: .URL)
        }

        // The editable content is authoritative when a captured representation
        // also contains an older plain-text pasteboard value.
        item.setString(payload.content, forType: .string)
    }
}

struct ClipboardCardInteractionView<Content: View>: NSViewRepresentable {
    let item: ClipboardItem
    let selection: [ClipboardItem]
    let store: (any ClipboardStore)?
    let accessibilitySummary: String
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onActivate: () -> Void
    let onSessionChanged: (Bool) -> Void
    let content: () -> Content

    func makeNSView(context: Context) -> ClipboardCardInteractionNSView<Content> {
        ClipboardCardInteractionNSView(
            item: item,
            selection: selection,
            store: store,
            accessibilitySummary: accessibilitySummary,
            isSelected: isSelected,
            onSelect: onSelect,
            onActivate: onActivate,
            onSessionChanged: onSessionChanged,
            content: content)
    }

    func updateNSView(_ view: ClipboardCardInteractionNSView<Content>, context: Context) {
        view.item = item
        view.selection = selection
        view.store = store
        view.accessibilitySummary = accessibilitySummary
        view.isSelected = isSelected
        view.onSelect = onSelect
        view.onActivate = onActivate
        view.onSessionChanged = onSessionChanged
        view.hostingView.rootView = content()
        view.schedulePayloadPrefetch()
    }
}

@MainActor
final class ClipboardCardInteractionNSView<Content: View>: NSView, NSDraggingSource, NSAccessibilityButton {
    var item: ClipboardItem {
        didSet { configureAccessibility() }
    }
    var selection: [ClipboardItem]
    var store: (any ClipboardStore)?
    var accessibilitySummary: String {
        didSet { configureAccessibility() }
    }
    var isSelected = false {
        didSet { configureAccessibility() }
    }
    var onSelect: (NSEvent.ModifierFlags) -> Void
    var onActivate: () -> Void
    var onSessionChanged: (Bool) -> Void

    fileprivate let hostingView: NSHostingView<Content>
    private var mouseDownEvent: NSEvent?
    private var isForwardingMouseEvent = false
    private var dragStarted = false
    private var dragInteractionHeld = false
    private var dragPreparationTask: Task<Void, Never>?
    private var cachedPayloads: [Int64: ClipboardPayload] = [:]
    private var cachedItemSnapshots: [Int64: ClipboardItem] = [:]
    private var payloadLoadTasks: [Int64: Task<Void, Never>] = [:]

    init(
        item: ClipboardItem,
        selection: [ClipboardItem],
        store: (any ClipboardStore)?,
        accessibilitySummary: String,
        isSelected: Bool,
        onSelect: @escaping (NSEvent.ModifierFlags) -> Void,
        onActivate: @escaping () -> Void,
        onSessionChanged: @escaping (Bool) -> Void,
        content: () -> Content
    ) {
        self.item = item
        self.selection = selection
        self.store = store
        self.accessibilitySummary = accessibilitySummary
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onSessionChanged = onSessionChanged
        hostingView = NSHostingView(rootView: content())
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        configureAccessibility()
        addSubview(hostingView)
    }

    private func configureAccessibility() {
        setAccessibilityIdentifier("clipboard.card.\(item.id ?? -1)")
        setAccessibilityLabel(accessibilitySummary)
        setAccessibilityValue(isSelected ? "Selezionato" : nil)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect([])
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePayloadPrefetch()
    }

    fileprivate func schedulePayloadPrefetch() {
        guard let store, let id = item.id else { return }
        guard cachedItemSnapshots[id] != item else { return }
        payloadLoadTasks[id]?.cancel()
        payloadLoadTasks[id] = nil
        cachedPayloads[id] = nil
        cachedItemSnapshots[id] = item

        // Each visible card only warms its own payload. Loading the entire current
        // selection from every card multiplies memory use for large selections.
        let candidate = item
        payloadLoadTasks[id] = Task { @MainActor [weak self, store] in
            let payload = try? await store.payload(for: candidate)
            guard !Task.isCancelled, let self else { return }
            if let payload {
                self.cachedPayloads[id] = payload
            }
            self.payloadLoadTasks[id] = nil
        }
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            return hostingView.hitTest(localPoint) ?? hostingView
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard !isForwardingMouseEvent else {
            super.mouseDown(with: event)
            return
        }
        guard !event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        mouseDownEvent = event
        dragStarted = false
        if event.clickCount > 1 {
            onSelect(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            onActivate()
        }
        forwardMouseEvent { hostingView.mouseDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isForwardingMouseEvent else {
            super.mouseDragged(with: event)
            return
        }
        guard !event.modifierFlags.contains(.control) else {
            super.mouseDragged(with: event)
            return
        }
        forwardMouseEvent { hostingView.mouseDragged(with: event) }
        guard !dragStarted, let mouseDownEvent else { return }
        let start = convert(mouseDownEvent.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }

        dragStarted = true
        let modifiers = mouseDownEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let draggedItems = resolvedSelection(for: modifiers)
        guard !draggedItems.isEmpty, let store else {
            dragStarted = false
            return
        }

        if !selection.contains(where: { $0.id == item.id }) || modifiers.contains(.command) || modifiers.contains(.shift) {
            onSelect(modifiers)
        }

        dragInteractionHeld = true
        onSessionChanged(true)
        dragPreparationTask = Task { @MainActor [weak self, store, draggedItems, mouseDownEvent] in
            var loaded: [Int64: ClipboardPayload] = [:]
            for candidate in draggedItems {
                guard !Task.isCancelled, let id = candidate.id,
                      let payload = try? await store.payload(for: candidate) else {
                    self?.finishDragPreparation()
                    return
                }
                loaded[id] = payload
            }

            guard !Task.isCancelled, let self,
                  self.mouseDownEvent != nil,
                  let window = self.window,
                  window.isVisible else {
                self?.finishDragPreparation()
                return
            }

            let pasteboardItems = Self.makePasteboardItems(for: draggedItems, payloads: loaded)
            guard !pasteboardItems.isEmpty else {
                self.finishDragPreparation()
                return
            }
            let preview = self.dragPreview(for: pasteboardItems.count)
            let draggingItems = pasteboardItems.enumerated().map { index, item -> NSDraggingItem in
                let draggingItem = NSDraggingItem(pasteboardWriter: item)
                let offset = CGFloat(index) * 3
                draggingItem.setDraggingFrame(
                    self.bounds.offsetBy(dx: offset, dy: -offset),
                    contents: preview)
                return draggingItem
            }
            self.dragPreparationTask = nil
            _ = self.beginDraggingSession(with: draggingItems, event: mouseDownEvent, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isForwardingMouseEvent else {
            super.mouseUp(with: event)
            return
        }
        guard !event.modifierFlags.contains(.control) else {
            super.mouseUp(with: event)
            return
        }
        if !dragStarted, let mouseDownEvent {
            let modifiers = mouseDownEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onSelect(modifiers)
        }
        if dragPreparationTask != nil {
            dragPreparationTask?.cancel()
            dragPreparationTask = nil
            finishDragPreparation()
        }
        forwardMouseEvent { hostingView.mouseUp(with: event) }
        mouseDownEvent = nil
        dragStarted = false
    }

    private func forwardMouseEvent(_ forward: () -> Void) {
        isForwardingMouseEvent = true
        defer { isForwardingMouseEvent = false }
        forward()
    }

    private func dragPreview(for itemCount: Int) -> NSImage? {
        let scale = window?.backingScaleFactor ?? 1
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        if itemCount > 1 {
            image.lockFocus()
            let badge = "\(itemCount)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ]
            let badgeSize = badge.size(withAttributes: attributes)
            let badgeRect = NSRect(
                x: image.size.width - badgeSize.width - 8,
                y: image.size.height - badgeSize.height - 8,
                width: badgeSize.width + 8,
                height: badgeSize.height + 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            badge.draw(
                at: NSPoint(x: badgeRect.minX + 4, y: badgeRect.minY + 2),
                withAttributes: attributes)
            image.unlockFocus()
        }
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            [.copy, .move]
        case .outsideApplication:
            .copy
        @unknown default:
            .copy
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finishDragPreparation()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    private func resolvedSelection(for modifiers: NSEvent.ModifierFlags) -> [ClipboardItem] {
        let containsItem = selection.contains { $0.id == item.id }
        let chosen: [ClipboardItem]
        if containsItem {
            chosen = selection
        } else if modifiers.contains(.command) || modifiers.contains(.shift) {
            chosen = selection + [item]
        } else {
            chosen = [item]
        }

        var seen = Set<Int64>()
        return chosen.filter { candidate in
            guard let id = candidate.id else { return false }
            return seen.insert(id).inserted
        }
    }

    private func finishDragPreparation() {
        guard dragInteractionHeld else { return }
        dragInteractionHeld = false
        onSessionChanged(false)
    }

    private static func makePasteboardItems(
        for items: [ClipboardItem],
        payloads: [Int64: ClipboardPayload]
    ) -> [NSPasteboardItem] {
        let ids = items.compactMap(\.id)
        let idData = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data()
        var result: [NSPasteboardItem] = []

        for item in items {
            guard let id = item.id, let payload = payloads[id] else { return [] }
            let fileVariants: [ClipboardPayload]
            if payload.files.count > 1 {
                fileVariants = payload.files.map { file in
                    var singleFilePayload = payload
                    singleFilePayload.files = [file]
                    singleFilePayload.content = file.name
                    return singleFilePayload
                }
            } else {
                fileVariants = [payload]
            }

            for variant in fileVariants {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setData(idData, forType: ClipboardDragTypes.internalItemsType)
                ClipboardPasteboardItemWriter.write(variant, to: pasteboardItem, plainText: false)
                result.append(pasteboardItem)
            }
        }
        return result
    }
}
