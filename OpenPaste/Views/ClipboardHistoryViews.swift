import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardSearchPanel: String, CaseIterable, Identifiable {
    case field = "Campo"
    case results = "Risultati"
    var id: String { rawValue }
}

struct ClipboardHistoryToolbar: View {
    let collections: [ClipboardCollection]
    let sourceAppBundleIDs: [String]
    @Binding var selectedCollectionID: Int64?
    @Binding var searchText: String
    @Binding var retentionPolicy: ClipboardRetentionPolicy
    @Binding var searchFilter: ClipboardFilter
    @Binding var searchPanel: ClipboardSearchPanel
    @Binding var isSearchFocused: Bool
    @FocusState private var searchFieldFocused: Bool
    let onSearchChanged: (String) -> Void
    let onCreateCollection: () -> Void
    let onEditCollection: (ClipboardCollection) -> Void
    let onDeleteCollection: () -> Void
    let onClearHistory: () -> Void
    let onReorderCollections: ([Int64]) -> Void
    let onMoveItems: ([Int64], Int64?) -> Void
    let onImportPayload: (ClipboardPayload, Int64?) -> Void
    let actions: ClipboardUIActions

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Cerca", text: $searchText)
                    .accessibilityIdentifier("clipboard.search")
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onChange(of: searchText) { _, query in onSearchChanged(query) }
                    .onChange(of: searchFieldFocused) { _, focused in isSearchFocused = focused }
                    .frame(minWidth: 120, maxWidth: 210)
                if !searchText.isEmpty {
                    Button { searchText = ""; onSearchChanged("") } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                if !searchText.isEmpty || !searchFilter.isEmpty {
                    Picker("Ricerca", selection: $searchPanel) {
                        ForEach(ClipboardSearchPanel.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 136)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    collectionButton(id: nil, title: "Cronologia", color: .secondary)
                    ForEach(collections) { collection in
                        if let id = collection.id {
                            collectionButton(id: id, title: collection.name, color: Color(hex: collection.colorHex))
                                .contextMenu {
                                    Button("Rinomina e colore…") { onEditCollection(collection) }
                                }
                        }
                    }
                    Button(action: onCreateCollection) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Nuova raccolta")
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 520)

            Menu {
                Section("Conservazione") {
                    Picker("Conserva per", selection: $retentionPolicy) {
                        ForEach(ClipboardRetentionPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }
                Section("Filtro") {
                    Picker("Tipo", selection: Binding(
                        get: { searchFilter.kind },
                        set: { searchFilter.kind = $0 })) {
                            Text("Tutti i tipi").tag(ClipboardItemKind?.none)
                            ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(Optional(kind))
                            }
                        }
                    Picker("App", selection: Binding(
                        get: { searchFilter.sourceAppBundleID },
                        set: { searchFilter.sourceAppBundleID = $0 })) {
                            Text("Tutte le app").tag(String?.none)
                            ForEach(sourceAppBundleIDs, id: \.self) { source in
                                Text(source.split(separator: ".").last.map(String.init) ?? source).tag(Optional(source))
                            }
                        }
                    DatePicker("Da", selection: Binding(
                        get: { searchFilter.fromDate ?? .now },
                        set: { searchFilter.fromDate = $0 }), displayedComponents: .date)
                    DatePicker("A", selection: Binding(
                        get: { searchFilter.toDate ?? .now },
                        set: { value in searchFilter.toDate = Calendar.current.date(byAdding: .second, value: 86_399, to: value) ?? value }), displayedComponents: .date)
                    Button("Azzera filtri") { searchFilter = ClipboardFilter() }
                }
                Section {
                    Button("Nuova raccolta…", systemImage: "folder.badge.plus", action: onCreateCollection)
                    if let selected = collections.first(where: { $0.id == selectedCollectionID }) {
                        Button("Rinomina raccolta…", systemImage: "pencil") { onEditCollection(selected) }
                        Button("Elimina raccolta…", systemImage: "trash", role: .destructive, action: onDeleteCollection)
                    }
                    Menu("Pausa acquisizione") {
                        Button("15 minuti") { actions.pause(.fifteenMinutes) }
                        Button("1 ora") { actions.pause(.oneHour) }
                        Button("Fino alla ripresa") { actions.pause(.untilResumed) }
                    }
                    Button("Riprendi acquisizione") { actions.resume() }
                    Button("Svuota cronologia…", systemImage: "clock.badge.xmark", role: .destructive, action: onClearHistory)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.thinMaterial, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .onChange(of: isSearchFocused) { _, focused in searchFieldFocused = focused }
    }

    private static let collectionDragType = "com.openpaste.collection-order"

    private func collectionButton(id: Int64?, title: String, color: Color) -> some View {
        let selected = selectedCollectionID == id
        return Button { selectedCollectionID = id } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? .white.opacity(0.18) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.2 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onDrag {
            guard let id else { return NSItemProvider() }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.collectionDragType,
                visibility: .ownProcess) { completion in
                    completion(Data(String(id).utf8), nil)
                    return nil
                }
            return provider
        }
        .onDrop(of: [Self.collectionDragType] + ClipboardDropSupport.acceptedTypes, isTargeted: nil) { providers in
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(Self.collectionDragType) }) {
                provider.loadDataRepresentation(forTypeIdentifier: Self.collectionDragType) { data, _ in
                    guard let data, let raw = String(data: data, encoding: .utf8),
                          let source = Int64(raw), let destination = id else { return }
                    Task { @MainActor in
                        var order = collections.compactMap(\.id)
                        order.removeAll { $0 == source }
                        guard let targetIndex = order.firstIndex(of: destination) else { return }
                        order.insert(source, at: targetIndex)
                        onReorderCollections(order)
                    }
                }
                return true
            }
            return ClipboardDropSupport.accept(
                providers: providers,
                onItems: { onMoveItems($0, id) },
                onPayload: { onImportPayload($0, id) })
        }
    }
}

struct ClipboardHistoryItems: View {
    @State private var targetedCardID: Int64?
    @State private var isEmptyDropTargeted = false
    @State private var lastAutoScrollAt = Date.distantPast
    @State private var cardFrames: [Int64: CGRect] = [:]

    let items: [ClipboardItem]
    let collections: [ClipboardCollection]
    let isCompact: Bool
    let selectedCollectionID: Int64?
    let isSearching: Bool
    let activeID: Int64?
    let selectedIDs: Set<Int64>
    let store: (any ClipboardStore)?
    let onSelect: (ClipboardItem, NSEvent.ModifierFlags) -> Void
    let onActivate: (ClipboardItem) -> Void
    let onMove: ([ClipboardItem], Int64?) -> Void
    let onMoveIDs: ([Int64], Int64?) -> Void
    let onDelete: ([ClipboardItem]) -> Void
    let onRename: (ClipboardItem, String?) -> Void
    let onEdit: (ClipboardItem) -> Void
    let onOpen: (ClipboardItem) -> Void
    let onPreview: (ClipboardItem) -> Void
    let onClassify: (ClipboardItem, ClipboardItemKind, String?) -> Void
    let onSessionChanged: (Bool) -> Void
    let onImport: (ClipboardPayload) -> Void
    let onNearEnd: (Int) -> Void
    let onReorderItems: ([Int64], Int64) -> Void

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                isSearching ? "Nessun risultato" : (selectedCollectionID == nil ? "Cronologia vuota" : "Raccolta vuota"),
                systemImage: isSearching ? "magnifyingglass" : "clipboard",
                description: Text(isSearching ? "Prova con un altro testo o filtro." : "Copia un elemento in un’altra app per salvarlo qui."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isEmptyDropTargeted ? Color.accentColor.opacity(0.85) : .clear, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .padding(8)
                }
                .onDrop(of: ClipboardDropSupport.acceptedTypes, isTargeted: $isEmptyDropTargeted) { providers in
                    ClipboardDropSupport.accept(providers: providers, onItems: { ids in
                        onMoveIDs(ids, selectedCollectionID)
                    }, onPayload: onImport)
                }
        } else {
            GeometryReader { geometry in
                let side = PillWindowGeometry.cardSide(availableHeight: geometry.size.height, isCompact: isCompact)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .center, spacing: 12) {
                            ForEach(items) { item in
                                ClipboardCardInteractionView(
                                    item: item,
                                    selection: items.filter { selectedIDs.contains($0.id ?? -1) },
                                    store: store,
                                    accessibilitySummary: accessibilitySummary(for: item),
                                    isSelected: activeID == item.id || (item.id.map(selectedIDs.contains) ?? false),
                                    onSelect: { onSelect(item, $0) },
                                    onActivate: { onActivate(item) },
                                    onSessionChanged: onSessionChanged) {
                                        ClipboardItemCard(
                                            item: item,
                                            collections: collections,
                                            previewLineLimit: isCompact ? 5 : 12,
                                            isActive: activeID == item.id,
                                            isSelected: item.id.map(selectedIDs.contains) ?? false,
                                            store: store,
                                            onMove: { collectionID in
                                                let selection = selectionFor(item)
                                                onMove(selection, collectionID)
                                            },
                                            onDelete: { onDelete(selectionFor(item)) },
                                            onRename: { onRename(item, $0) },
                                            onEdit: { onEdit(item) },
                                            onOpen: { onOpen(item) },
                                            onPreview: { onPreview(item) },
                                            onClassify: { onClassify(item, $0, $1) },
                                            isCollectionView: selectedCollectionID != nil,
                                            onSessionChanged: onSessionChanged)
                                    }
                                    .id(item.id ?? Int64.min)
                                    .frame(width: side, height: side)
                                    .background {
                                        GeometryReader { cardGeometry in
                                            Color.clear.preference(
                                                key: ClipboardCardFramesKey.self,
                                                value: item.id.map { [$0: cardGeometry.frame(in: .named("clipboard.carousel"))] } ?? [:])
                                        }
                                    }
                                    .onAppear {
                                        if let index = items.firstIndex(of: item) { onNearEnd(index) }
                                    }
                                    .onDrop(of: ClipboardDropSupport.acceptedTypes, delegate: ClipboardCardDropDelegate(
                                        itemID: item.id,
                                        itemIndex: items.firstIndex(of: item) ?? 0,
                                        items: items,
                                        cardFrame: cardFrames[item.id ?? -1] ?? .zero,
                                        viewportWidth: geometry.size.width,
                                        lastAutoScrollAt: $lastAutoScrollAt,
                                        onTargetChanged: { targetedCardID = $0 ? item.id : (targetedCardID == item.id ? nil : targetedCardID) },
                                        onAutoScroll: { targetID in withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(targetID, anchor: .center) } },
                                        onItems: { ids in
                                            if let targetID = item.id { onReorderItems(ids, targetID) }
                                        },
                                        onPayload: onImport))
                                    .overlay {
                                        if targetedCardID == item.id {
                                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                                .strokeBorder(Color.accentColor, lineWidth: 4)
                                                .padding(-2)
                                                .allowsHitTesting(false)
                                        }
                                    }

                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollIndicators(.hidden)
                    .coordinateSpace(name: "clipboard.carousel")
                    .onPreferenceChange(ClipboardCardFramesKey.self) { cardFrames = $0 }
                    .onChange(of: activeID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onDrop(of: ClipboardDropSupport.acceptedTypes, isTargeted: nil) { providers in
                        ClipboardDropSupport.accept(
                            providers: providers,
                            onItems: { ids in
                                onMoveIDs(ids, selectedCollectionID)
                            },
                            onPayload: onImport)
                    }
                }
            }
        }
    }

    private func accessibilitySummary(for item: ClipboardItem) -> String {
        var parts = [item.customTitle ?? item.title ?? item.kind.displayName]
        switch item.kind {
        case .text, .code, .link:
            let normalizedContent = item.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !normalizedContent.isEmpty {
                let preview = String(normalizedContent.prefix(180))
                parts.append(normalizedContent.count > 180 ? preview + "…" : preview)
            }
        case .file:
            break
        case .image:
            if let width = item.imageWidth, let height = item.imageHeight {
                parts.append("\(width) × \(height)")
            }
        case .color:
            parts.append(item.colorHex ?? item.content)
        }
        if selectedCollectionID == nil {
            parts.append(item.lastCopiedAt.formatted(.relative(presentation: .named)))
        }
        if let bundleID = item.sourceAppBundleID {
            parts.append(bundleID.split(separator: ".").last.map(String.init) ?? bundleID)
        }
        return parts.joined(separator: ", ")
    }

    private func selectionFor(_ item: ClipboardItem) -> [ClipboardItem] {
        guard let id = item.id, selectedIDs.contains(id), selectedIDs.count > 1 else { return [item] }
        return items.filter { $0.id.map(selectedIDs.contains) ?? false }
    }
}

private struct ClipboardCardFramesKey: PreferenceKey {
    static let defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
private struct ClipboardCardDropDelegate: DropDelegate {
    let itemID: Int64?
    let itemIndex: Int
    let items: [ClipboardItem]
    let cardFrame: CGRect
    let viewportWidth: CGFloat
    @Binding var lastAutoScrollAt: Date
    let onTargetChanged: (Bool) -> Void
    let onAutoScroll: (Int64) -> Void
    let onItems: ([Int64]) -> Void
    let onPayload: (ClipboardPayload) -> Void

    func dropEntered(info: DropInfo) { onTargetChanged(true) }
    func dropExited(info: DropInfo) { onTargetChanged(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let viewportX = cardFrame.minX + info.location.x
        let direction: Int
        if !cardFrame.isEmpty && viewportX < 32 { direction = -1 }
        else if !cardFrame.isEmpty && viewportX > viewportWidth - 32 { direction = 1 }
        else { direction = 0 }

        let now = Date()
        if direction != 0, now.timeIntervalSince(lastAutoScrollAt) >= 0.18 {
            let nextIndex = min(max(itemIndex + direction, 0), items.count - 1)
            if let nextID = items[safe: nextIndex]?.id, nextID != itemID {
                lastAutoScrollAt = now
                onAutoScroll(nextID)
            }
        }
        let isInternal = info.hasItemsConforming(to: [ClipboardDropSupport.internalItemsType.rawValue])
        return DropProposal(operation: isInternal ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let types = ClipboardDropSupport.acceptedTypes.compactMap { UTType($0) }
        return ClipboardDropSupport.accept(
            providers: info.itemProviders(for: types),
            onItems: onItems,
            onPayload: onPayload)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let collections: [ClipboardCollection]
    let previewLineLimit: Int
    let isActive: Bool
    let isSelected: Bool
    let store: (any ClipboardStore)?
    let onMove: (Int64?) -> Void
    let onDelete: () -> Void
    let onRename: (String?) -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onPreview: () -> Void
    let onClassify: (ClipboardItemKind, String?) -> Void
    let isCollectionView: Bool
    let onSessionChanged: (Bool) -> Void

    @State private var payload: ClipboardPayload?
    @State private var appIcon: NSImage?
    @State private var appAccent: Color?
    @State private var isRenaming = false
    @State private var titleDraft = ""

    private var headerColor: Color {
        appAccent ?? Color(hex: item.kind.accentHex)
    }

    private var headerForeground: Color {
        guard let color = NSColor(headerColor).usingColorSpace(.sRGB) else { return .white }

        func linearized(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linearized(color.redComponent)
            + 0.7152 * linearized(color.greenComponent)
            + 0.0722 * linearized(color.blueComponent)
        return luminance > 0.179 ? .black : .white
    }

    private var headerTitle: String {
        if let customTitle = item.customTitle, !customTitle.isEmpty { return customTitle }
        if item.kind == .link { return "Link" }
        return item.title ?? item.kind.displayName
    }

    private var canClassifyAsColor: Bool {
        let value = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^#?(?:[0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !isCollectionView {
                        Text(item.lastCopiedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .opacity(0.78)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                sourceIcon
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .foregroundStyle(headerForeground)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .leading)
            .background(headerColor)

            ClipboardItemPreview(item: item, payload: payload, lineLimit: previewLineLimit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(item.kind == .color ? 7 : 14)
                .clipped()

            HStack(spacing: 6) {
                Text(footerText)
                Spacer(minLength: 0)
                if isSelected && !isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.purple)
                        .accessibilityLabel("Selezionato")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(item.kind == .color ? Color(hex: item.colorHex ?? item.content) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .strokeBorder(
                    isActive ? Color.blue : (isSelected ? Color.purple : Color.white.opacity(0.12)),
                    style: StrokeStyle(lineWidth: isActive ? 3 : (isSelected ? 2 : 1), dash: isSelected && !isActive ? [5, 3] : []))
        }
        .shadow(color: isActive ? Color.blue.opacity(0.2) : .black.opacity(0.08), radius: isActive ? 8 : 3, y: 2)
        .contextMenu {
            Button("Apri", systemImage: "arrow.up.right.square", action: onOpen)
            Button("Anteprima", systemImage: "eye", action: onPreview)
            Button("Rinomina…", systemImage: "pencil") { titleDraft = item.customTitle ?? item.title ?? ""; isRenaming = true }
            if item.kind == .text || item.kind == .code {
                Button(item.kind == .code ? "Modifica codice…" : "Modifica testo…", systemImage: "square.and.pencil", action: onEdit)
            }
            if item.kind == .text {
                Menu("Classifica come") {
                    Button("Codice") { onClassify(.code, "swift") }
                    if canClassifyAsColor { Button("Colore") { onClassify(.color, nil) } }
                }
            } else if item.kind == .code {
                Menu("Linguaggio") {
                    ForEach(["swift", "javascript", "typescript", "python", "json", "sql", "shell", "html", "css"], id: \.self) { value in
                        Button(value.uppercased()) { onClassify(.code, value) }
                    }
                }
            }
            Menu("Sposta in raccolta") {
                Button("Cronologia") { onMove(nil) }
                ForEach(collections) { collection in
                    if let id = collection.id { Button(collection.name) { onMove(id) } }
                }
            }
            Button("Elimina…", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .alert("Rinomina elemento", isPresented: $isRenaming) {
            TextField("Nome", text: $titleDraft)
            Button("Salva") { onRename(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : titleDraft) }
            Button("Annulla", role: .cancel) {}
        }
        .onChange(of: isRenaming) { _, isPresented in onSessionChanged(isPresented) }
        .task(id: item.assetPath ?? item.content) {
            payload = nil
            if let store { payload = try? await store.payload(for: item) }
        }
        .task(id: item.sourceAppBundleID) {
            guard let bundleID = item.sourceAppBundleID,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            appIcon = icon
            appAccent = icon.dominantColor()
        }
    }

    private var footerText: String {
        switch item.kind {
        case .text, .code: "\(item.content.count) caratteri"
        case .file:
            if let files = payload?.files, !files.isEmpty {
                files.count == 1 ? files[0].name : "\(files.count) file"
            } else {
                item.title ?? "File"
            }
        case .image:
            if let width = item.imageWidth, let height = item.imageHeight { "\(width) × \(height)" }
            else { "Immagine" }
        case .link: URL(string: item.content)?.host ?? item.content
        case .color: item.colorHex ?? item.content
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let appIcon {
            Image(nsImage: appIcon).resizable().scaledToFit()
        } else {
            Image(systemName: item.kind.symbolName).resizable().scaledToFit().padding(9)
                .foregroundStyle(Color(hex: item.kind.accentHex))
                .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sourceAppName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
            ?? bundleID.split(separator: ".").last.map(String.init)
            ?? bundleID
    }
}

private struct ClipboardItemPreview: View {
    let item: ClipboardItem
    let payload: ClipboardPayload?
    let lineLimit: Int
    @State private var linkThumbnailData: Data?

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let image = imagePreview {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("photo", item.customTitle ?? item.title ?? "Immagine")
                }
            case .file:
                filePreview
            case .color:
                colorPreview
            case .code:
                codePreview
            case .link:
                linkPreview
            case .text:
                textPreview
            }
        }
        .task(id: item.linkImageURL) {
            guard let rawURL = item.linkImageURL, let url = URL(string: rawURL) else { return }
            linkThumbnailData = await LinkThumbnailLoader.shared.imageData(for: url)
        }
    }

    private var imagePreview: NSImage? {
        guard let data = payload?.representations.first(where: {
            UTType($0.type)?.conforms(to: .image) == true
        })?.data else { return nil }
        return NSImage(data: data)
    }

    @ViewBuilder
    private var filePreview: some View {
        let file = payload?.files.first
        if let file, let url = file.resolvedURL(), url.pathExtension.lowercased() == "pdf",
           let document = PDFDocument(url: url), let page = document.page(at: 0),
           let image = page.thumbnail(of: CGSize(width: 420, height: 320), for: .mediaBox) as NSImage? {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: file?.resolvedURL()?.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.blue)
                Text(file?.name ?? item.payloadFileName).font(.headline).lineLimit(3)
                Text(file?.resolvedURL()?.pathExtension.uppercased() ?? "FILE")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var colorPreview: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: item.colorHex ?? item.content))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.2)))
            Text(item.colorHex ?? item.content).font(.system(.body, design: .monospaced).weight(.medium))
        }
    }

    private var codePreview: some View {
        ScrollView {
            Text(highlightedCode(item.content, language: item.codeLanguage))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
    }

    private var linkPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let linkThumbnailData, let image = NSImage(data: linkThumbnailData) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(height: 92)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(item.customTitle ?? item.title ?? URL(string: item.content)?.host ?? item.content)
                .font(.system(.body, weight: .semibold))
                .lineLimit(3)
            Text(item.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textPreview: some View {
        Group {
            if let payload,
               payload.representations.contains(where: {
                   ["public.rtf", "text/rtf", "public.html", "text/html"].contains($0.type.lowercased())
               }) {
                let rich = ClipboardTextFormatting.attributedText(from: payload)
                Text(AttributedString(legibleRichPreview(rich)))
                    .lineLimit(lineLimit)
            } else {
                Text(item.customTitle ?? item.content)
                    .lineLimit(lineLimit)
            }
        }
        .font(.system(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.9)], startPoint: .center, endPoint: .bottom)
                    .frame(height: 24)
                    .allowsHitTesting(false)
            }
    }

    private func legibleRichPreview(_ attributed: NSAttributedString) -> NSAttributedString {
        let preview = NSMutableAttributedString(attributedString: attributed)
        preview.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 0, length: preview.length))
        return preview
    }

    private func placeholder(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline).lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func highlightedCode(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = .primary
        let lang = (language ?? "").lowercased()
        let patterns = [
            (#"//.*|#.*"#, Color(nsColor: .secondaryLabelColor)),
            (#"\b(func|let|var|const|class|def|return|if|else|for|while|import|from|async|await|SELECT|FROM|WHERE|true|false|null|nil)\b"#, Color.blue),
            (#"\"[^\"\\]*(?:\\.[^\"\\]*)*\"|'[^'\\]*(?:\\.[^'\\]*)*'"#, Color.green),
            (#"\b\d+(?:\.\d+)?\b"#, Color.orange)
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: lang == "sql" ? [.caseInsensitive] : []) else { continue }
            let ns = code as NSString
            for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result[range].foregroundColor = color
            }
        }
        return result
    }
}

struct ClipboardTextEditor: View {
    let item: ClipboardItem
    let store: (any ClipboardStore)?
    let onSave: (ClipboardPayload) async throws -> Void
    let onSessionChanged: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var payload: ClipboardPayload
    @State private var attributedText: NSAttributedString
    @State private var language: String
    @State private var isLoaded = false
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        item: ClipboardItem,
        store: (any ClipboardStore)?,
        onSave: @escaping (ClipboardPayload) async throws -> Void,
        onSessionChanged: @escaping (Bool) -> Void
    ) {
        self.item = item
        self.store = store
        self.onSave = onSave
        self.onSessionChanged = onSessionChanged
        _payload = State(initialValue: ClipboardPayload.restoring(item))
        _attributedText = State(initialValue: NSAttributedString(string: item.content))
        _language = State(initialValue: item.codeLanguage ?? "swift")
    }

    private var hasRichText: Bool {
        payload.representations.contains { $0.type == UTType.rtf.identifier || $0.type == UTType.html.identifier }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.kind == .code ? "Modifica codice" : "Modifica testo")
                    .font(.headline)
                Spacer()
                if item.kind == .code {
                    Picker("Linguaggio", selection: $language) {
                        ForEach(["swift", "javascript", "typescript", "python", "json", "sql", "shell", "html", "css"], id: \.self) {
                            Text($0.uppercased()).tag($0)
                        }
                    }
                    .frame(width: 150)
                }
            }
            ClipboardRichTextView(
                attributedText: $attributedText,
                allowsRichText: hasRichText,
                isCode: item.kind == .code)
                .frame(minWidth: 560, minHeight: 340)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Annulla", role: .cancel) { dismiss() }
                Button("Salva") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do {
                            let updated = try ClipboardTextFormatting.updatedPayload(payload, text: attributedText, language: item.kind == .code ? language : nil)
                            try await onSave(updated)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isLoaded || isSaving)
            }
        }
        .padding(18)
        .task {
            guard let store else {
                attributedText = NSAttributedString(string: item.content)
                isLoaded = true
                return
            }
            guard let loaded = try? await store.payload(for: item) else { return }
            payload = loaded
            attributedText = ClipboardTextFormatting.attributedText(from: loaded)
            isLoaded = true
        }
        .onAppear { onSessionChanged(true) }
        .onDisappear { onSessionChanged(false) }
    }
}

private struct ClipboardRichTextView: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    let allowsRichText: Bool
    let isCode: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = allowsRichText
        view.importsGraphics = allowsRichText
        view.allowsUndo = true
        view.font = isCode ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(attributedText)
        scrollView.documentView = view
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scrollView.documentView as? NSTextView else { return }
        view.isRichText = allowsRichText
        if let storage = view.textStorage, !storage.isEqual(to: attributedText) {
            storage.setAttributedString(attributedText)
        }
        if isCode { view.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClipboardRichTextView
        init(_ parent: ClipboardRichTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView,
                  let value = view.textStorage?.copy() as? NSAttributedString else { return }
            parent.attributedText = value
        }
    }
}

struct ClipboardItemPreviewWindow: View {
    let item: ClipboardItem
    let store: (any ClipboardStore)?
    let onSessionChanged: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var payload: ClipboardPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.customTitle ?? item.title ?? item.kind.displayName).font(.headline)
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ClipboardItemPreview(item: item, payload: payload, lineLimit: 200)
                .frame(minWidth: 520, minHeight: 380)
            Text(item.content).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(18)
        .task {
            if let store { payload = try? await store.payload(for: item) }
        }
        .onAppear { onSessionChanged(true) }
        .onDisappear { onSessionChanged(false) }
    }
}

extension ClipboardItemKind {
    var displayName: String {
        switch self {
        case .text: "Testo"
        case .link: "Link"
        case .image: "Immagine"
        case .file: "File"
        case .code: "Codice"
        case .color: "Colore"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .color: "paintpalette"
        }
    }

    var accentHex: String {
        switch self {
        case .text: "#8E8E93"
        case .link: "#0A84FF"
        case .image: "#AF52DE"
        case .file: "#FF9F0A"
        case .code: "#30B0C7"
        case .color: "#FF2D55"
        }
    }
}

extension ClipboardItem {
    var payloadFileName: String {
        assetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1)
    }
}

private extension NSImage {
    func dominantColor() -> Color? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let xStride = max(1, bitmap.pixelsWide / 16)
        let yStride = max(1, bitmap.pixelsHigh / 16)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var samples = 0.0

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: yStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: xStride) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                guard pixel.alphaComponent > 0.2, brightness < 0.96 else { continue }
                red += pixel.redComponent
                green += pixel.greenComponent
                blue += pixel.blueComponent
                samples += 1
            }
        }
        guard samples > 0 else { return nil }
        let average = NSColor(
            calibratedRed: red / samples,
            green: green / samples,
            blue: blue / samples,
            alpha: 1)
        var hue = CGFloat.zero
        var saturation = CGFloat.zero
        var brightness = CGFloat.zero
        var alpha = CGFloat.zero
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(
            hue: Double(hue),
            saturation: Double(max(0.42, saturation)),
            brightness: Double(min(0.78, max(0.48, brightness))))
    }
}

extension Notification.Name {
    static let clipboardOpenItemRequested = Notification.Name("clipboardOpenItemRequested")
}
