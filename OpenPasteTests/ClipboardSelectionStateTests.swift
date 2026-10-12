import AppKit
import Testing
@testable import OpenPaste

@MainActor
struct ClipboardSelectionStateTests {
    @Test
    func commandClickTogglesMultiSelectionAndMovesActiveInVisualOrder() {
        let state = ClipboardSelectionState()
        let items = makeItems([10, 20, 30])
        state.setVisibleItems(items)
        #expect(state.activeID == 10)

        state.select(items[0])
        state.select(items[1], modifiers: .command)
        state.select(items[2], modifiers: .command)
        #expect(state.selectedItemIDs == [10, 20, 30])
        #expect(state.activeID == 30)

        state.select(items[2], modifiers: .command)
        #expect(state.selectedItemIDs == [10, 20])
        #expect(state.activeID == 10)
    }

    @Test
    func shiftClickAndArrowExtendFromTheOriginalAnchor() {
        let state = ClipboardSelectionState()
        let items = makeItems([1, 2, 3, 4, 5])
        state.setVisibleItems(items)
        state.select(items[1])
        state.select(items[4], modifiers: .shift)
        #expect(state.selectedItemIDs == [2, 3, 4, 5])
        #expect(state.activeID == 5)

        state.moveActive(by: -1, extending: true)
        #expect(state.selectedItemIDs == [2, 3, 4])
        #expect(state.activeID == 4)
    }

    @Test
    func selectAllAndNavigationFollowVisibleOrder() {
        let state = ClipboardSelectionState()
        let items = makeItems([8, 6, 4])
        state.setVisibleItems(items)
        state.selectAll()
        #expect(state.selectedItemIDs == [8, 6, 4])

        state.moveActive(toFirst: false)
        #expect(state.activeID == 4)
        state.moveActive(by: -1)
        #expect(state.activeID == 6)
        #expect(state.selectedItemIDs == [6])
    }

    @Test
    func activatingFirstVisibleItemSelectsTheMostRecentCopy() {
        let state = ClipboardSelectionState()
        state.setVisibleItems(makeItems([3, 2, 1]))
        state.select(makeItems([2])[0])
        state.select(makeItems([1])[0], modifiers: .command)

        state.setVisibleItems(makeItems([4, 3, 2, 1]))
        #expect(state.activeID == 1)

        state.activateFirstVisibleItem()
        #expect(state.activeID == 4)
        #expect(state.selectedItemIDs == [4])
    }

    @Test
    func activatingFirstVisibleItemWaitsForLoadedItems() {
        let state = ClipboardSelectionState()
        state.setVisibleItems([])
        state.activateFirstVisibleItem()
        #expect(state.activeID == nil)

        state.setVisibleItems(makeItems([7, 5]))
        #expect(state.activeID == 7)
    }

    private func makeItems(_ ids: [Int64]) -> [ClipboardItem] {
        ids.map { id in
            ClipboardItem(
                id: id,
                kind: .text,
                content: "Item \(id)",
                deduplicationKey: "text:\(id)",
                canonicalURL: nil,
                title: nil,
                linkDescription: nil,
                sourceAppBundleID: nil,
                firstCopiedAt: .now,
                lastCopiedAt: .now,
                expiresAt: nil,
                isInHistory: true,
                collectionID: nil)
        }
    }
}
