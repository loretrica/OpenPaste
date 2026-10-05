import AppKit
import QuickLook
import QuickLookUI
import UniformTypeIdentifiers

@MainActor
final class ClipboardQuickLookController: NSViewController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewItems: [ClipboardQuickLookItem] = []
    private var onControlChanged: (Bool) -> Void
    private var temporaryPreviewURLs: [URL] = []
    private var securityScopedURLs: [URL] = []
    private var controlsPreviewPanel = false
    private var interactionIsHeld = false
    nonisolated(unsafe) private var closeObserver: NSObjectProtocol?

    init(onControlChanged: @escaping (Bool) -> Void) {
        self.onControlChanged = onControlChanged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    func preview(_ item: ClipboardItem, using store: (any ClipboardStore)?) async {
        let previousTemporaryURLs = temporaryPreviewURLs
        let previousSecurityScopedURLs = securityScopedURLs
        temporaryPreviewURLs = []
        securityScopedURLs = []
        guard let urls = await previewURLs(for: item, using: store), !urls.isEmpty else {
            cleanupTemporaryPreview()
            temporaryPreviewURLs = previousTemporaryURLs
            securityScopedURLs = previousSecurityScopedURLs
            NSSound.beep()
            return
        }
        previewItems = urls.map {
            ClipboardQuickLookItem(
                url: $0,
                title: item.customTitle ?? item.title ?? $0.lastPathComponent)
        }
        guard let panel = QLPreviewPanel.shared() else {
            cleanupTemporaryPreview()
            previousTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            previousSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            NSSound.beep()
            return
        }

        holdInteractionIfNeeded()
        installCloseObserver(for: panel)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        let currentURLs = Set(temporaryPreviewURLs)
        for url in previousTemporaryURLs where !currentURLs.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        previousSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let previewItem: ClipboardQuickLookItem? = MainActor.assumeIsolated {
            guard previewItems.indices.contains(index) else { return nil }
            return previewItems[index]
        }
        return previewItem
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            controlsPreviewPanel = true
            holdInteractionIfNeeded()
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard controlsPreviewPanel else { return }
            controlsPreviewPanel = false
            handlePreviewPanelClose(panel: panel)
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            handlePreviewPanelClose()
        }
    }

    private func handlePreviewPanelClose(panel: QLPreviewPanel? = nil) {
        controlsPreviewPanel = false
        let closingPanel = panel ?? QLPreviewPanel.shared()
        closingPanel?.dataSource = nil
        closingPanel?.delegate = nil
        cleanupTemporaryPreview()
        previewItems = []
        removeCloseObserver()
        releaseInteractionIfNeeded()
    }

    private func installCloseObserver(for panel: QLPreviewPanel) {
        removeCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self, panel] _ in
            MainActor.assumeIsolated {
                self?.handlePreviewPanelClose(panel: panel)
            }
        }
    }

    private func removeCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    private func holdInteractionIfNeeded() {
        guard !interactionIsHeld else { return }
        interactionIsHeld = true
        onControlChanged(true)
    }

    private func releaseInteractionIfNeeded() {
        guard interactionIsHeld else { return }
        interactionIsHeld = false
        onControlChanged(false)
    }

    private func previewURLs(
        for item: ClipboardItem,
        using store: (any ClipboardStore)?
    ) async -> [URL]? {
        let payload: ClipboardPayload
        if let store, let storedPayload = try? await store.payload(for: item) {
            payload = storedPayload
        } else {
            payload = ClipboardPayload.restoring(item)
        }

        if payload.kind == .file {
            let files = payload.files.compactMap { file -> URL? in
                guard let url = file.resolvedURL(),
                      FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                if file.bookmark != nil, url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                return url
            }
            return files.isEmpty ? nil : files
        }

        if payload.kind == .image {
            guard let representation = payload.representations.first(where: {
                UTType($0.type)?.conforms(to: .image) == true
            }) else { return nil }
            guard let fileExtension = UTType(representation.type)?.preferredFilenameExtension else {
                return nil
            }
            guard let url = writeTemporaryPreview(
                representation.data,
                fileExtension: fileExtension)
            else { return nil }
            return [url]
        }

        if payload.kind == .link,
           let url = URL(string: payload.content) {
            guard let previewURL = writeTemporaryPreview(
                Self.webLocationData(for: url),
                fileExtension: "webloc")
            else { return nil }
            return [previewURL]
        }

        guard let previewURL = writeTemporaryPreview(
            Data(payload.content.utf8),
            fileExtension: "txt")
        else { return nil }
        return [previewURL]
    }

    private func writeTemporaryPreview(_ data: Data, fileExtension: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenPaste-Preview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: url, options: .atomic)
            temporaryPreviewURLs.append(url)
            return url
        } catch {
            return nil
        }
    }

    private func cleanupTemporaryPreview() {
        temporaryPreviewURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryPreviewURLs = []
        securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopedURLs = []
    }

    private static func webLocationData(for url: URL) -> Data {
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>URL</key><string>\(url.absoluteString)</string></dict></plist>
        """
        return Data(contents.utf8)
    }
}

private final class ClipboardQuickLookItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
        super.init()
    }
}
