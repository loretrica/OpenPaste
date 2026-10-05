import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ClipboardSelectionState {
    private(set) var activeID: Int64?
    private(set) var selectedIDs: Set<Int64> = []
    private(set) var anchorID: Int64?

    var isMultiSelecting: Bool { selectedIDs.count > 1 }

    func select(_ item: ClipboardItem, modifiers: NSEvent.ModifierFlags = []) {
        guard let id = item.id else { return }
        if modifiers.contains(.shift), anchorID != nil {
            // The list order is supplied through setVisibleItems before interaction.
            extendSelection(to: id)
        } else if modifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if activeID == id {
                    activeID = visibleIDs.first(where: selectedIDs.contains)
                }
            } else {
                selectedIDs.insert(id)
                activeID = id
            }
            if selectedIDs.isEmpty {
                activeID = nil
                anchorID = nil
            } else if anchorID == nil {
                anchorID = id
            }
        } else {
            activeID = id
            selectedIDs = [id]
            anchorID = id
        }
    }

    func setVisibleItems(_ items: [ClipboardItem]) {
        visibleIDs = items.compactMap(\.id)
        selectedIDs.formIntersection(Set(visibleIDs))
        if let activeID, !visibleIDs.contains(activeID) {
            self.activeID = nil
        }
        if let anchorID, !visibleIDs.contains(anchorID) {
            self.anchorID = nil
        }
        if activeID == nil {
            activeID = visibleIDs.first(where: selectedIDs.contains) ?? visibleIDs.first
        }
    }

    func moveActive(by offset: Int, extending: Bool = false) {
        guard !visibleIDs.isEmpty else { clear(); return }
        let currentIndex = activeID.flatMap(visibleIDs.firstIndex(of:)) ?? (offset < 0 ? visibleIDs.count : -1)
        let nextIndex = min(max(0, currentIndex + offset), visibleIDs.count - 1)
        selectID(visibleIDs[nextIndex], extending: extending)
    }

    func moveActive(toFirst: Bool, extending: Bool = false) {
        guard let id = toFirst ? visibleIDs.first : visibleIDs.last else { return }
        selectID(id, extending: extending)
    }

    func selectAll() {
        selectedIDs = Set(visibleIDs)
        if activeID == nil { activeID = visibleIDs.first }
        if anchorID == nil { anchorID = activeID }
    }

    func clear() {
        activeID = nil
        selectedIDs.removeAll()
        anchorID = nil
    }

    var selectedItemIDs: [Int64] {
        visibleIDs.filter(selectedIDs.contains)
    }

    private var visibleIDs: [Int64] = []

    private func selectID(_ id: Int64, extending: Bool) {
        if extending {
            if anchorID == nil { anchorID = activeID ?? id }
            extendSelection(to: id)
        } else {
            activeID = id
            selectedIDs = [id]
            anchorID = id
        }
    }

    private func extendSelection(to id: Int64) {
        guard let anchorID,
              let anchorIndex = visibleIDs.firstIndex(of: anchorID),
              let targetIndex = visibleIDs.firstIndex(of: id)
        else {
            selectID(id, extending: false)
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        selectedIDs = Set(visibleIDs[lower...upper])
        activeID = id
    }
}
