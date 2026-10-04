import SwiftUI

struct ClipboardHistoryToolbar: View {
    let collections: [ClipboardCollection]
    @Binding var selectedCollectionID: Int64?
    @Binding var searchText: String
    @Binding var retentionPolicy: ClipboardRetentionPolicy
    let onSearchChanged: (String) -> Void
    let onCreateCollection: () -> Void
    let onDeleteCollection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Vista", selection: $selectedCollectionID) {
                Text("Cronologia").tag(Int64?.none)
                ForEach(collections) { collection in
                    if let id = collection.id {
                        Text(collection.name).tag(Optional(id))
                    }
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Cerca negli appunti", text: $searchText)
                .accessibilityIdentifier("clipboard.search")
                .textFieldStyle(.plain)
                .onChange(of: searchText) { _, query in
                    onSearchChanged(query)
                }

            Picker("Conservazione", selection: $retentionPolicy) {
                ForEach(ClipboardRetentionPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Menu {
                Button("Nuova raccolta", systemImage: "folder.badge.plus", action: onCreateCollection)
                if selectedCollectionID != nil {
                    Divider()
                    Button("Elimina raccolta", systemImage: "trash", role: .destructive, action: onDeleteCollection)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding()
    }
}

struct ClipboardHistoryItems: View {
    let items: [ClipboardItem]
    let collections: [ClipboardCollection]
    let isCompact: Bool
    let selectedCollectionID: Int64?
    let isSearching: Bool
    let onMove: (ClipboardItem, Int64?) -> Void
    let onRemoveFromHistory: (ClipboardItem) -> Void
    let onDelete: (ClipboardItem) -> Void

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                !isSearching
                    ? (selectedCollectionID == nil ? "Cronologia vuota" : "Raccolta vuota")
                    : "Nessun risultato",
                systemImage: !isSearching ? "clipboard" : "magnifyingglass",
                description: Text(
                    !isSearching
                        ? "Copia testo o un link in un’altra app per salvarlo qui."
                        : "Prova con un’altra parola."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let side = PillWindowGeometry.cardSide(
                    availableHeight: geometry.size.height,
                    isCompact: isCompact)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .center, spacing: 12) {
                        ForEach(items) { item in
                            ClipboardItemCard(
                                item: item,
                                collections: collections,
                                previewLineLimit: isCompact ? 5 : 12,
                                onMove: { onMove(item, $0) },
                                onRemoveFromHistory: { onRemoveFromHistory(item) },
                                onDelete: { onDelete(item) })
                                .frame(width: side, height: side)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let collections: [ClipboardCollection]
    let previewLineLimit: Int
    let onMove: (Int64?) -> Void
    let onRemoveFromHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: item.kind == .link ? "link" : "text.alignleft")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(item.lastCopiedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            ClipboardItemPreview(item: item, lineLimit: previewLineLimit)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            ClipboardItemContextMenu(
                item: item,
                collections: collections,
                onMove: onMove,
                onRemoveFromHistory: onRemoveFromHistory,
                onDelete: onDelete)
        }
    }
}

private struct ClipboardItemPreview: View {
    let item: ClipboardItem
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title ?? item.content)
                .font(.body)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.title != nil || item.kind == .link {
                Text(item.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let source = item.sourceAppBundleID {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ClipboardItemContextMenu: View {
    let item: ClipboardItem
    let collections: [ClipboardCollection]
    let onMove: (Int64?) -> Void
    let onRemoveFromHistory: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if !collections.isEmpty {
            Menu("Assegna a raccolta") {
                ForEach(collections) { collection in
                    if let id = collection.id {
                        Button(collection.name) { onMove(id) }
                    }
                }
            }
            if item.collectionID != nil {
                Button("Rimuovi dalla raccolta") { onMove(nil) }
            }
        }
        if item.isInHistory {
            Button("Rimuovi dalla cronologia", systemImage: "clock.badge.xmark") {
                onRemoveFromHistory()
            }
        }
        Button("Elimina definitivamente", systemImage: "trash", role: .destructive) {
            onDelete()
        }
    }
}
