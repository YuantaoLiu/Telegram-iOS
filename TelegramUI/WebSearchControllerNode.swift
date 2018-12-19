import Foundation
import AsyncDisplayKit
import Postbox
import SwiftSignalKit
import Display
import TelegramCore
import LegacyComponents

private struct WebSearchContextResultStableId: Hashable {
    let result: ChatContextResult
    
    var hashValue: Int {
        return result.id.hashValue
    }
    
    static func ==(lhs: WebSearchContextResultStableId, rhs: WebSearchContextResultStableId) -> Bool {
        return lhs.result == rhs.result
    }
}

private struct WebSearchEntry: Comparable, Identifiable {
    let index: Int
    let result: ChatContextResult
    
    var stableId: WebSearchContextResultStableId {
        return WebSearchContextResultStableId(result: self.result)
    }
    
    static func ==(lhs: WebSearchEntry, rhs: WebSearchEntry) -> Bool {
        return lhs.index == rhs.index && lhs.result == rhs.result
    }
    
    static func <(lhs: WebSearchEntry, rhs: WebSearchEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(account: Account, theme: PresentationTheme, interfaceState: WebSearchInterfaceState, controllerInteraction: WebSearchControllerInteraction) -> GridItem {
        return WebSearchItem(account: account, theme: theme, interfaceState: interfaceState, result: self.result, controllerInteraction: controllerInteraction)
    }
}

private struct WebSearchTransition {
    let deleteItems: [Int]
    let insertItems: [GridNodeInsertItem]
    let updateItems: [GridNodeUpdateItem]
    let entryCount: Int
    let hasMore: Bool
}

private func preparedTransition(from fromEntries: [WebSearchEntry], to toEntries: [WebSearchEntry], hasMore: Bool, account: Account, theme: PresentationTheme, interfaceState: WebSearchInterfaceState, controllerInteraction: WebSearchControllerInteraction) -> WebSearchTransition {
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let insertions = indicesAndItems.map { GridNodeInsertItem(index: $0.0, item: $0.1.item(account: account, theme: theme, interfaceState: interfaceState, controllerInteraction: controllerInteraction), previousIndex: $0.2) }
    let updates = updateIndices.map { GridNodeUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, theme: theme, interfaceState: interfaceState, controllerInteraction: controllerInteraction)) }
    
    return WebSearchTransition(deleteItems: deleteIndices, insertItems: insertions, updateItems: updates, entryCount: toEntries.count, hasMore: hasMore)
}

private func gridNodeLayoutForContainerLayout(size: CGSize) -> GridNodeLayoutType {
    let side = floorToScreenPixels((size.width - 3.0) / 4.0)
    return .fixed(itemSize: CGSize(width: side, height: side), fillWidth: true, lineSpacing: 1.0, itemSpacing: 1.0)
}


private struct WebSearchRecentQueryStableId: Hashable {
    let query: String
    
    var hashValue: Int {
        return query.hashValue
    }
    
    static func ==(lhs: WebSearchRecentQueryStableId, rhs: WebSearchRecentQueryStableId) -> Bool {
        return lhs.query == rhs.query
    }
}

private struct WebSearchRecentQueryEntry: Comparable, Identifiable {
    let index: Int
    let query: String
    
    var stableId: WebSearchRecentQueryStableId {
        return WebSearchRecentQueryStableId(query: self.query)
    }
    
    static func ==(lhs: WebSearchRecentQueryEntry, rhs: WebSearchRecentQueryEntry) -> Bool {
        return lhs.index == rhs.index && lhs.query == rhs.query
    }
    
    static func <(lhs: WebSearchRecentQueryEntry, rhs: WebSearchRecentQueryEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(account: Account, theme: PresentationTheme, strings: PresentationStrings, controllerInteraction: WebSearchControllerInteraction, header: ListViewItemHeader) -> ListViewItem {
        return WebSearchRecentQueryItem(account: account, theme: theme, strings: strings, query: self.query, controllerInteraction: controllerInteraction, header: header)
    }
}

private struct WebSearchRecentTransition {
    let deletions: [ListViewDeleteItem]
    let insertions: [ListViewInsertItem]
    let updates: [ListViewUpdateItem]
}

private func preparedWebSearchRecentTransition(from fromEntries: [WebSearchRecentQueryEntry], to toEntries: [WebSearchRecentQueryEntry], account: Account, theme: PresentationTheme, strings: PresentationStrings, controllerInteraction: WebSearchControllerInteraction, header: ListViewItemHeader) -> WebSearchRecentTransition {
    let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
    
    let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
    let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, theme: theme, strings: strings, controllerInteraction: controllerInteraction, header: header), directionHint: nil) }
    let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, theme: theme, strings: strings, controllerInteraction: controllerInteraction, header: header), directionHint: nil) }
    
    return WebSearchRecentTransition(deletions: deletions, insertions: insertions, updates: updates)
}

class WebSearchControllerNode: ASDisplayNode {
    private let account: Account
    private let peer: Peer?
    private var theme: PresentationTheme
    private var strings: PresentationStrings
    private let mode: WebSearchMode
    
    private let controllerInteraction: WebSearchControllerInteraction
    private var webSearchInterfaceState: WebSearchInterfaceState
    private let webSearchInterfaceStatePromise: ValuePromise<WebSearchInterfaceState>
    
    private let segmentedBackgroundNode: ASDisplayNode
    private let segmentedSeparatorNode: ASDisplayNode
    private let segmentedControl: UISegmentedControl
    
    private let toolbarBackgroundNode: ASDisplayNode
    private let toolbarSeparatorNode: ASDisplayNode
    private let cancelButton: HighlightableButtonNode
    private let sendButton: HighlightableButtonNode
    private let badgeNode: WebSearchBadgeNode
    
    private let attributionNode: ASImageNode
    
    private let recentQueriesPlaceholder: ImmediateTextNode
    private let recentQueriesNode: ListView
    private var enqueuedRecentTransitions: [(WebSearchRecentTransition, Bool)] = []
    
    private let gridNode: GridNode
    private var enqueuedTransitions: [(WebSearchTransition, Bool)] = []
    private var dequeuedInitialTransitionOnLayout = false
    
    private var currentExternalResults: ChatContextResultCollection?
    private var currentProcessedResults: ChatContextResultCollection?
    private var currentEntries: [WebSearchEntry]?
    private var hasMore = false
    private var isLoadingMore = false
    
    private let hiddenMediaId = Promise<String?>(nil)
    private var hiddenMediaDisposable: Disposable?
    
    private let results = ValuePromise<ChatContextResultCollection?>(nil, ignoreRepeated: true)
    
    private let disposable = MetaDisposable()
    private let loadMoreDisposable = MetaDisposable()
    
    private var recentDisposable: Disposable?
    
    private var containerLayout: (ContainerViewLayout, CGFloat)?
    
    var requestUpdateInterfaceState: (Bool, (WebSearchInterfaceState) -> WebSearchInterfaceState) -> Void = { _, _ in }
    var cancel: (() -> Void)?
    var dismissInput: (() -> Void)?
    
    init(account: Account, theme: PresentationTheme, strings: PresentationStrings, controllerInteraction: WebSearchControllerInteraction, peer: Peer?, mode: WebSearchMode) {
        self.account = account
        self.theme = theme
        self.strings = strings
        self.controllerInteraction = controllerInteraction
        self.peer = peer
        self.mode = mode
        
        self.webSearchInterfaceState = WebSearchInterfaceState(presentationData: account.telegramApplicationContext.currentPresentationData.with { $0 })
        self.webSearchInterfaceStatePromise = ValuePromise(self.webSearchInterfaceState, ignoreRepeated: true)
        
        self.segmentedBackgroundNode = ASDisplayNode()
        self.segmentedSeparatorNode = ASDisplayNode()
        
        self.segmentedControl = UISegmentedControl(items: [strings.WebSearch_Images, strings.WebSearch_GIFs])
        self.segmentedControl.selectedSegmentIndex = 0
        
        self.toolbarBackgroundNode = ASDisplayNode()
        self.toolbarSeparatorNode = ASDisplayNode()
        
        self.attributionNode = ASImageNode()
        
        self.cancelButton = HighlightableButtonNode()
        self.sendButton = HighlightableButtonNode()
        
        self.badgeNode = WebSearchBadgeNode(theme: theme)
        
        self.gridNode = GridNode()
        self.gridNode.backgroundColor = theme.list.plainBackgroundColor
        
        self.recentQueriesNode = ListView()
        self.recentQueriesNode.backgroundColor = theme.list.plainBackgroundColor
        
        self.recentQueriesPlaceholder = ImmediateTextNode()
        
        super.init()
        
        self.setViewBlock({
            return UITracingLayerView()
        })
        
        self.addSubnode(self.gridNode)
        self.addSubnode(self.recentQueriesNode)
        self.addSubnode(self.segmentedBackgroundNode)
        self.addSubnode(self.segmentedSeparatorNode)
        if case .media = mode {
            self.view.addSubview(self.segmentedControl)
        }
        self.addSubnode(self.toolbarBackgroundNode)
        self.addSubnode(self.toolbarSeparatorNode)
        self.addSubnode(self.cancelButton)
        self.addSubnode(self.sendButton)
        self.addSubnode(self.attributionNode)
        self.addSubnode(self.badgeNode)
        
        self.segmentedControl.addTarget(self, action: #selector(self.indexChanged), for: .valueChanged)
        self.cancelButton.addTarget(self, action: #selector(self.cancelPressed), forControlEvents: .touchUpInside)
        self.sendButton.addTarget(self, action: #selector(self.sendPressed), forControlEvents: .touchUpInside)
        
        self.applyPresentationData()
        
        self.disposable.set((combineLatest(self.results.get(), self.webSearchInterfaceStatePromise.get())
        |> deliverOnMainQueue).start(next: { [weak self] results, interfaceState in
            if let strongSelf = self {
                strongSelf.updateInternalResults(results, interfaceState: interfaceState)
            }
        }))
        
        let previousRecentItems = Atomic<[WebSearchRecentQueryEntry]?>(value: nil)
        self.recentDisposable = (combineLatest(webSearchRecentQueries(postbox: self.account.postbox), self.webSearchInterfaceStatePromise.get())
        |> deliverOnMainQueue).start(next: { [weak self] queries, interfaceState in
            if let strongSelf = self {
                var entries: [WebSearchRecentQueryEntry] = []
                for i in 0 ..< queries.count {
                    entries.append(WebSearchRecentQueryEntry(index: i, query: queries[i]))
                }
                
                let header = ChatListSearchItemHeader(type: .recentPeers, theme: interfaceState.presentationData.theme, strings:interfaceState.presentationData.strings, actionTitle: strings.WebSearch_RecentSectionClear.uppercased(), action: {
                    _ = clearRecentWebSearchQueries(postbox: strongSelf.account.postbox).start()
                })
                
                let previousEntries = previousRecentItems.swap(entries)
                
                let transition = preparedWebSearchRecentTransition(from: previousEntries ?? [], to: entries, account: strongSelf.account, theme: interfaceState.presentationData.theme, strings: interfaceState.presentationData.strings, controllerInteraction: strongSelf.controllerInteraction, header: header)
                strongSelf.enqueueRecentTransition(transition, firstTime: previousEntries == nil)
            }
        })
        
        self.gridNode.visibleItemsUpdated = { [weak self] visibleItems in
            if let strongSelf = self, let bottom = visibleItems.bottom, let entries = strongSelf.currentEntries {
                if bottom.0 >= entries.count - 8 {
                    strongSelf.loadMore()
                }
            }
        }
        
        self.gridNode.scrollingInitiated = { [weak self] in
            self?.dismissInput?()
        }
        
        self.recentQueriesNode.beganInteractiveDragging = { [weak self] in
            self?.dismissInput?()
        }
        
        self.sendButton.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self, strongSelf.badgeNode.alpha > 0.0 {
                if highlighted {
                    strongSelf.badgeNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.badgeNode.alpha = 0.4
                } else {
                    strongSelf.badgeNode.alpha = 1.0
                    strongSelf.badgeNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.hiddenMediaDisposable = (self.hiddenMediaId.get()
        |> deliverOnMainQueue).start(next: { [weak self] id in
            if let strongSelf = self {
                strongSelf.controllerInteraction.hiddenMediaId = id
                
                strongSelf.gridNode.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? WebSearchItemNode {
                        itemNode.updateHiddenMedia()
                    }
                }
            }
        })
    }
    
    deinit {
        self.disposable.dispose()
        self.recentDisposable?.dispose()
        self.loadMoreDisposable.dispose()
        self.hiddenMediaDisposable?.dispose()
    }
    
    func updatePresentationData(theme: PresentationTheme, strings: PresentationStrings) {
        let themeUpdated = theme !== self.theme
        self.theme = theme
        self.strings = strings
        
        self.applyPresentationData(themeUpdated: themeUpdated)
    }
    
    func applyPresentationData(themeUpdated: Bool = true) {
        self.cancelButton.setTitle(self.strings.Common_Cancel, with: Font.regular(17.0), with: self.theme.rootController.navigationBar.accentTextColor, for: .normal)
        
        if let selectionState = self.controllerInteraction.selectionState {
            let sendEnabled = selectionState.count() > 0
            let color = sendEnabled ? self.theme.rootController.navigationBar.accentTextColor : self.theme.rootController.navigationBar.disabledButtonColor
            self.sendButton.setTitle(self.strings.MediaPicker_Send, with: Font.medium(17.0), with: color, for: .normal)
        }
        
        if themeUpdated {
            self.backgroundColor = self.theme.chatList.backgroundColor
            
            self.segmentedBackgroundNode.backgroundColor = self.theme.rootController.navigationBar.backgroundColor
            self.segmentedSeparatorNode.backgroundColor = self.theme.rootController.navigationBar.separatorColor
            self.segmentedControl.tintColor = self.theme.rootController.navigationBar.accentTextColor
            self.toolbarBackgroundNode.backgroundColor = self.theme.rootController.navigationBar.backgroundColor
            self.toolbarSeparatorNode.backgroundColor = self.theme.rootController.navigationBar.separatorColor
            
            self.attributionNode.image = generateTintedImage(image: UIImage(bundleImageName: "Media Grid/Giphy"), color: self.theme.list.itemSecondaryTextColor)
        }
    }
    
    func animateIn(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), to: self.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
    }
    
    func animateOut(completion: (() -> Void)? = nil) {
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: self.layer.position.x, y: self.layer.position.y + self.layer.bounds.size.height), duration: 0.2, timingFunction: kCAMediaTimingFunctionEaseInEaseOut, removeOnCompletion: false, completion: { _ in
            completion?()
        })
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.containerLayout = (layout, navigationBarHeight)
        
        var insets = layout.insets(options: [.input])
        insets.top += navigationBarHeight
        
        let segmentedHeight: CGFloat = self.segmentedControl.superview != nil ? 40.0 : 5.0
        let panelY: CGFloat = insets.top - UIScreenPixel - 4.0
        
        transition.updateFrame(node: self.segmentedBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelY), size: CGSize(width: layout.size.width, height: segmentedHeight)))
        transition.updateFrame(node: self.segmentedSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelY + segmentedHeight), size: CGSize(width: layout.size.width, height: UIScreenPixel)))
        
        var controlSize = self.segmentedControl.sizeThatFits(layout.size)
        controlSize.width = layout.size.width - layout.safeInsets.left - layout.safeInsets.right - 8.0 * 2.0
        
        transition.updateFrame(view: self.segmentedControl, frame: CGRect(origin: CGPoint(x: layout.safeInsets.left + floor((layout.size.width - layout.safeInsets.left - layout.safeInsets.right - controlSize.width) / 2.0), y: panelY + floor((segmentedHeight - controlSize.height) / 2.0)), size: controlSize))
        
        insets.top -= 4.0
        
        let toolbarHeight: CGFloat = 44.0
        let toolbarY = layout.size.height - toolbarHeight - insets.bottom
        transition.updateFrame(node: self.toolbarBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toolbarY), size: CGSize(width: layout.size.width, height: toolbarHeight + insets.bottom)))
        transition.updateFrame(node: self.toolbarSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toolbarY), size: CGSize(width: layout.size.width, height: UIScreenPixel)))
        
        if let image = self.attributionNode.image {
            transition.updateFrame(node: self.attributionNode, frame: CGRect(origin: CGPoint(x: floor((layout.size.width - image.size.width) / 2.0), y: toolbarY + floor((toolbarHeight - image.size.height) / 2.0)), size: image.size))
            transition.updateAlpha(node: self.attributionNode, alpha: self.webSearchInterfaceState.state?.scope == .gifs ? 1.0 : 0.0)
        }
        
        let toolbarPadding: CGFloat = 10.0
        let cancelSize = self.cancelButton.measure(CGSize(width: layout.size.width, height: toolbarHeight))
        transition.updateFrame(node: self.cancelButton, frame: CGRect(origin: CGPoint(x: toolbarPadding + layout.safeInsets.left, y: toolbarY), size: CGSize(width: cancelSize.width, height: toolbarHeight)))
        
        let sendSize = self.sendButton.measure(CGSize(width: layout.size.width, height: toolbarHeight))
        let sendFrame = CGRect(origin: CGPoint(x: layout.size.width - toolbarPadding - layout.safeInsets.right - sendSize.width, y: toolbarY), size: CGSize(width: sendSize.width, height: toolbarHeight))
        transition.updateFrame(node: self.sendButton, frame: sendFrame)
        
        if let selectionState = self.controllerInteraction.selectionState {
            self.sendButton.isHidden = false
            
            let previousSendEnabled = self.sendButton.isEnabled
            let sendEnabled = selectionState.count() > 0
            self.sendButton.isEnabled = sendEnabled
            if sendEnabled != previousSendEnabled {
                let color = sendEnabled ? self.theme.rootController.navigationBar.accentTextColor : self.theme.rootController.navigationBar.disabledButtonColor
                self.sendButton.setTitle(self.strings.MediaPicker_Send, with: Font.medium(17.0), with: color, for: .normal)
            }
            
            let selectedCount = selectionState.count()
            let badgeText = String(selectedCount)
            if selectedCount > 0 && (self.badgeNode.text != badgeText || self.badgeNode.alpha < 1.0) {
                if transition.isAnimated {
                    var incremented = true
                    if let previousCount = Int(self.badgeNode.text) {
                        incremented = selectedCount > previousCount || self.badgeNode.alpha < 1.0
                    }
                    self.badgeNode.animateBump(incremented: incremented)
                }
                self.badgeNode.text = badgeText
                
                let badgeSize = self.badgeNode.measure(layout.size)
                transition.updateFrame(node: self.badgeNode, frame: CGRect(origin: CGPoint(x: sendFrame.minX - badgeSize.width - 6.0, y: toolbarY + 11.0), size: badgeSize))
                transition.updateAlpha(node: self.badgeNode, alpha: 1.0)
            } else if selectedCount == 0 {
                if transition.isAnimated {
                    self.badgeNode.animateOut()
                }
                let badgeSize = CGSize(width: 22.0, height: 22.0)
                transition.updateFrame(node: self.badgeNode, frame: CGRect(origin: CGPoint(x: sendFrame.minX - badgeSize.width - 6.0, y: toolbarY + 11.0), size: badgeSize))
                transition.updateAlpha(node: self.badgeNode, alpha: 0.0)
            }
        } else {
            self.sendButton.isHidden = true
        }
        
        let previousBounds = self.gridNode.bounds
        self.gridNode.bounds = CGRect(x: previousBounds.origin.x, y: previousBounds.origin.y, width: layout.size.width, height: layout.size.height)
        self.gridNode.position = CGPoint(x: layout.size.width / 2.0, y: layout.size.height / 2.0)
        
        insets.top += segmentedHeight
        insets.bottom += toolbarHeight
        self.gridNode.transaction(GridNodeTransaction(deleteItems: [], insertItems: [], updateItems: [], scrollToItem: nil, updateLayout: GridNodeUpdateLayout(layout: GridNodeLayout(size: layout.size, insets: insets, preloadSize: 400.0, type: gridNodeLayoutForContainerLayout(size: layout.size)), transition: .immediate), itemTransition: .immediate, stationaryItems: .none,updateFirstIndexInSectionOffset: nil), completion: { _ in })
        
        var duration: Double = 0.0
        var curve: UInt = 0
        switch transition {
            case .immediate:
                break
            case let .animated(animationDuration, animationCurve):
                duration = animationDuration
                switch animationCurve {
                    case .easeInOut:
                        break
                    case .spring:
                        curve = 7
                }
        }
        
        let listViewCurve: ListViewAnimationCurve
        if curve == 7 {
            listViewCurve = .Spring(duration: duration)
        } else {
            listViewCurve = .Default(duration: duration)
        }
        
        self.recentQueriesNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.recentQueriesNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous], scrollToItem: nil, updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: listViewCurve), stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
        
        if !self.dequeuedInitialTransitionOnLayout {
            self.dequeuedInitialTransitionOnLayout = true
            self.dequeueTransition()
        }
    }
    
    func updateInterfaceState(_ interfaceState: WebSearchInterfaceState, animated: Bool) {
        self.webSearchInterfaceState = interfaceState
        self.webSearchInterfaceStatePromise.set(self.webSearchInterfaceState)
        
        if let state = interfaceState.state {
            self.segmentedControl.selectedSegmentIndex = Int(state.scope.rawValue)
        }
        
        if let validLayout = self.containerLayout {
            self.containerLayoutUpdated(validLayout.0, navigationBarHeight: validLayout.1, transition: animated ? .animated(duration: 0.4, curve: .spring) : .immediate)
        }
    }
    
    func updateSelectionState(animated: Bool) {
        self.gridNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? WebSearchItemNode {
                itemNode.updateSelectionState(animated: animated)
            }
        }
        
        if let validLayout = self.containerLayout {
            self.containerLayoutUpdated(validLayout.0, navigationBarHeight: validLayout.1, transition: animated ? .animated(duration: 0.4, curve: .spring) : .immediate)
        }
    }
    
    func updateResults(_ results: ChatContextResultCollection?) {
        if self.currentExternalResults == results {
            return
        }
        self.currentExternalResults = results
        self.currentProcessedResults = results
        
        self.isLoadingMore = false
        self.loadMoreDisposable.set(nil)
        self.results.set(results)
    }
    
    func clearResults() {
        self.results.set(nil)
    }
    
    private func loadMore() {
        guard !self.isLoadingMore, let currentProcessedResults = self.currentProcessedResults, currentProcessedResults.results.count > 55, let nextOffset = currentProcessedResults.nextOffset else {
            return
        }
        self.isLoadingMore = true
        self.loadMoreDisposable.set((requestChatContextResults(account: self.account, botId: currentProcessedResults.botId, peerId: currentProcessedResults.peerId, query: currentProcessedResults.query, location: .single(currentProcessedResults.geoPoint), offset: nextOffset)
            |> deliverOnMainQueue).start(next: { [weak self] nextResults in
                guard let strongSelf = self, let nextResults = nextResults else {
                    return
                }
                strongSelf.isLoadingMore = false
                var results: [ChatContextResult] = []
                var existingIds = Set<String>()
                for result in currentProcessedResults.results {
                    results.append(result)
                    existingIds.insert(result.id)
                }
                for result in nextResults.results {
                    if !existingIds.contains(result.id) {
                        results.append(result)
                        existingIds.insert(result.id)
                    }
                }
                let mergedResults = ChatContextResultCollection(botId: currentProcessedResults.botId, peerId: currentProcessedResults.peerId, query: currentProcessedResults.query, geoPoint: currentProcessedResults.geoPoint, queryId: nextResults.queryId, nextOffset: nextResults.nextOffset, presentation: currentProcessedResults.presentation, switchPeer: currentProcessedResults.switchPeer, results: results, cacheTimeout: currentProcessedResults.cacheTimeout)
                strongSelf.currentProcessedResults = mergedResults
                strongSelf.results.set(mergedResults)
            }))
    }
    
    private func updateInternalResults(_ results: ChatContextResultCollection?, interfaceState: WebSearchInterfaceState) {
        var entries: [WebSearchEntry] = []
        var hasMore = false
        if let state = interfaceState.state, state.query.isEmpty {
        } else if let results = results {
            hasMore = results.nextOffset != nil
            
            var index = 0
            var resultIds = Set<WebSearchContextResultStableId>()
            for result in results.results {
                let entry = WebSearchEntry(index: index, result: result)
                if resultIds.contains(entry.stableId) {
                    continue
                } else {
                    resultIds.insert(entry.stableId)
                }
                entries.append(entry)
                index += 1
            }
        }
        
        let firstTime = self.currentEntries == nil
        let transition = preparedTransition(from: self.currentEntries ?? [], to: entries, hasMore: hasMore, account: self.account, theme: interfaceState.presentationData.theme, interfaceState: interfaceState, controllerInteraction: self.controllerInteraction)
        self.currentEntries = entries
        
        self.enqueueTransition(transition, firstTime: firstTime)
    }
    
    private func enqueueTransition(_ transition: WebSearchTransition, firstTime: Bool) {
        self.enqueuedTransitions.append((transition, firstTime))
        
        if self.containerLayout != nil {
            while !self.enqueuedTransitions.isEmpty {
                self.dequeueTransition()
            }
        }
    }
    
    private func dequeueTransition() {
        if let (transition, firstTime) = self.enqueuedTransitions.first {
            self.enqueuedTransitions.remove(at: 0)
            
            let completion: (GridNodeDisplayedItemRange) -> Void = { [weak self] visibleRange in
                if let strongSelf = self {
                }
            }
            
            if let state = self.webSearchInterfaceState.state {
                self.recentQueriesNode.isHidden = !state.query.isEmpty
            }
            
            self.hasMore = transition.hasMore
            self.gridNode.transaction(GridNodeTransaction(deleteItems: transition.deleteItems, insertItems: transition.insertItems, updateItems: transition.updateItems, scrollToItem: nil, updateLayout: nil, itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil, synchronousLoads: true), completion: completion)
        }
    }
    
    private func enqueueRecentTransition(_ transition: WebSearchRecentTransition, firstTime: Bool) {
        enqueuedRecentTransitions.append((transition, firstTime))
        
        if self.containerLayout != nil {
            while !self.enqueuedRecentTransitions.isEmpty {
                self.dequeueRecentTransition()
            }
        }
    }
    
    private func dequeueRecentTransition() {
        if let (transition, firstTime) = self.enqueuedRecentTransitions.first {
            self.enqueuedRecentTransitions.remove(at: 0)
            
            var options = ListViewDeleteAndInsertOptions()
            if firstTime {
                options.insert(.PreferSynchronousDrawing)
            } else {
                options.insert(.AnimateInsertion)
            }
            
            self.recentQueriesNode.transaction(deleteIndices: transition.deletions, insertIndicesAndItems: transition.insertions, updateIndicesAndItems: transition.updates, options: options, updateSizeAndInsets: nil, updateOpaqueState: nil, completion: { _ in
            })
        }
    }
    
    @objc private func indexChanged() {
        if let scope = WebSearchScope(rawValue: Int32(self.segmentedControl.selectedSegmentIndex)) {
            let _ = updateWebSearchSettingsInteractively(postbox: self.account.postbox) { _ -> WebSearchSettings in
                return WebSearchSettings(scope: scope)
            }.start()
            self.requestUpdateInterfaceState(true) { current in
                return current.withUpdatedScope(scope)
            }
        }
    }
    
    @objc private func cancelPressed() {
        self.cancel?()
    }
    
    @objc private func sendPressed() {
        if let results = self.currentExternalResults {
            self.controllerInteraction.sendSelected(results, nil)
        }
        self.cancel?()
    }
    
    func openResult(currentResult: ChatContextResult, present: @escaping (ViewController, Any?) -> Void) {
        if self.controllerInteraction.selectionState != nil {
            if let state = self.webSearchInterfaceState.state, state.scope == .images {
                if let results = self.currentProcessedResults?.results {
                    presentLegacyWebSearchGallery(account: self.account, peer: self.peer, theme: self.theme, results: results, current: currentResult, selectionContext: self.controllerInteraction.selectionState, editingContext: self.controllerInteraction.editingState, updateHiddenMedia: { [weak self] id in
                        self?.hiddenMediaId.set(.single(id))
                    }, initialLayout: self.containerLayout?.0, transitionHostView: { [weak self] in
                        return self?.gridNode.view
                    }, transitionView: { [weak self] result in
                        return self?.transitionNode(for: result)?.transitionView()
                    }, completed: { [weak self] result in
                        if let strongSelf = self, let results = strongSelf.currentExternalResults {
                            strongSelf.controllerInteraction.sendSelected(results, result)
                            strongSelf.cancel?()
                        }
                    }, present: present)
                }
            } else {
                if let results = self.currentProcessedResults?.results {
                    var entries: [WebSearchGalleryEntry] = []
                    var centralIndex: Int = 0
                    for i in 0 ..< results.count {
                        entries.append(WebSearchGalleryEntry(result: results[i]))
                        if results[i] == currentResult {
                            centralIndex = i
                        }
                    }
                    
                    let controller = WebSearchGalleryController(account: self.account, peer: self.peer, selectionState: self.controllerInteraction.selectionState, editingState: self.controllerInteraction.editingState, entries: entries, centralIndex: centralIndex, replaceRootController: { (controller, _) in
                        
                    }, baseNavigationController: nil, sendCurrent: { [weak self] result in
                        if let strongSelf = self, let results = strongSelf.currentExternalResults {
                            strongSelf.controllerInteraction.sendSelected(results, result)
                            strongSelf.cancel?()
                        }
                    })
                    self.hiddenMediaId.set((controller.hiddenMedia |> deliverOnMainQueue)
                    |> map { entry in
                        return entry?.result.id
                    })
                    present(controller, WebSearchGalleryControllerPresentationArguments(transitionArguments: { [weak self] entry -> GalleryTransitionArguments? in
                        if let strongSelf = self {
                            var transitionNode: WebSearchItemNode?
                            strongSelf.gridNode.forEachItemNode { itemNode in
                                if let itemNode = itemNode as? WebSearchItemNode, itemNode.item?.result.id == entry.result.id {
                                    transitionNode = itemNode
                                }
                            }
                            if let transitionNode = transitionNode {
                                return GalleryTransitionArguments(transitionNode: (transitionNode, { [weak transitionNode] in
                                        return transitionNode?.transitionView().snapshotContentTree(unhide: true)
                                }), addToTransitionSurface: { view in
                                    if let strongSelf = self {
                                        strongSelf.gridNode.view.superview?.insertSubview(view, aboveSubview: strongSelf.gridNode.view)
                                    }
                                })
                            }
                        }
                        return nil
                    }))
                }
            }
        } else {
            presentLegacyWebSearchEditor(account: self.account, theme: self.theme, result: currentResult, initialLayout: self.containerLayout?.0, updateHiddenMedia: { [weak self] id in
                self?.hiddenMediaId.set(.single(id))
            }, transitionHostView: { [weak self] in
                return self?.gridNode.view
            }, transitionView: { [weak self] result in
                return self?.transitionNode(for: result)?.transitionView()
            }, completed: { [weak self] result in
                if let strongSelf = self {
                    strongSelf.controllerInteraction.avatarCompleted(result)
                    strongSelf.cancel?()
                }
            }, present: present)
        }
    }
    
    private func transitionNode(for result: ChatContextResult) -> WebSearchItemNode? {
        var transitionNode: WebSearchItemNode?
        self.gridNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? WebSearchItemNode, itemNode.item?.result.id == result.id {
                transitionNode = itemNode
            }
        }
        return transitionNode
    }
}
