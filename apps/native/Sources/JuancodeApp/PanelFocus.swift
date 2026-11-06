import AppKit
import SwiftUI

extension PanelFocusTarget {
    /// The right-rail panel that shows this target; nil for the sessions sidebar.
    var railPanel: RightRailPanel? {
        switch self {
        case .sessions: nil
        case .prs: .prs
        case .linearTickets: .tickets
        case .chains: .chains
        case .oracles: .oracle
        }
    }
}

private struct PanelRowsKey: PreferenceKey {
    static var defaultValue: [PanelNavigationRow] { [] }
    static func reduce(value: inout [PanelNavigationRow], nextValue: () -> [PanelNavigationRow]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publish visible rows in display order, including only currently available actions.
    func panelNavigationRows(_ rows: [PanelNavigationRow]) -> some View {
        preference(key: PanelRowsKey.self, value: rows)
    }

    /// Install once around a panel. RightRailPanels already installs this for every rail.
    func panelNavigation(_ target: PanelFocusTarget) -> some View {
        modifier(PanelNavigationHost(target: target))
    }

    /// Attach inside a ScrollViewReader; row IDs must match the published IDs.
    func panelNavigationScroll(_ target: PanelFocusTarget, proxy: ScrollViewProxy) -> some View {
        modifier(PanelNavigationScroll(target: target, proxy: proxy))
    }

    /// Use the same `isFocused` predicate alongside hover to reveal row buttons.
    func panelRowFocus(_ target: PanelFocusTarget, id: String) -> some View {
        modifier(PanelRowFocus(target: target, id: id))
    }
}

private struct PanelNavigationScroll: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: PanelFocusTarget
    let proxy: ScrollViewProxy
    func body(content: Content) -> some View {
        content
            .onChange(of: model.panelNavigation.cursor.rowID, initial: true) { _, _ in reveal() }
            .onChange(of: model.panelFocusRequest) { _, _ in reveal() }
    }
    private func reveal() {
        guard model.panelNavigation.target == target, let id = model.panelNavigation.cursor.rowID else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

private struct PanelRowFocus: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: PanelFocusTarget
    let id: String
    func body(content: Content) -> some View {
        let focused = model.panelNavigation.isFocused(target, row: id)
        content.overlay {
            RoundedRectangle(cornerRadius: 5).stroke(focused ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }.overlay(alignment: .bottomTrailing) {
            if focused, let label = model.panelNavigation.selectedActionLabel {
                Text(label).font(.caption2).padding(3).background(.regularMaterial)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PanelNavigationHost: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: PanelFocusTarget
    func body(content: Content) -> some View {
        content.backgroundPreferenceValue(PanelRowsKey.self) { rows in
            PanelKeyHost(model: model, target: target, rows: rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }.onDisappear {
            if model.panelNavigation.target == target { model.focusTerminal() }
        }
    }
}

private struct PanelKeyHost: NSViewRepresentable {
    let model: AppModel
    let target: PanelFocusTarget
    let rows: [PanelNavigationRow]
    func makeNSView(context: Context) -> PanelKeyView { PanelKeyView() }
    func updateNSView(_ view: PanelKeyView, context: Context) {
        view.model = model
        view.target = target
        view.rows = rows
        view.request = model.panelFocusRequest
        // Defer model changes until SwiftUI has finished updating the view tree.
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.claimIfRequested()
            if view.window?.firstResponder === view { model.panelNavigation.update(view.rows) }
        }
    }
}

final class PanelKeyView: NSView {
    weak var model: AppModel?
    var target: PanelFocusTarget?
    var rows: [PanelNavigationRow] = []
    var request: PanelFocusRequest?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.claimIfRequested() }
    }
    func claimIfRequested() {
        guard let model, let target, let request, request.target == target,
              model.consumedPanelFocusSerial != request.serial, let window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(self) {
            model.consumedPanelFocusSerial = request.serial
            model.suppressTerminalAutoFocus = true
            model.panelNavigation.begin(target, rows: rows)
        }
    }
    /// Focus an already visible panel without opening a row or changing rail tabs.
    func focusForNavigation() -> Bool {
        guard let model, let target, window?.makeFirstResponder(self) == true else { return false }
        model.consumedPanelFocusSerial = model.panelFocusRequest?.serial
        model.suppressTerminalAutoFocus = true
        model.panelNavigation.begin(target, rows: rows)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if model?.panelNavigation.target == target {
            model?.panelNavigation.end()
            model?.suppressTerminalAutoFocus = false
        }
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard let model, window?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { super.keyDown(with: event); return }
        if event.keyCode == 53 { model.focusTerminal(); return }
        if !model.panelNavigation.handle(event.keyCode) { super.keyDown(with: event) }
    }
}

/// Find real, visible terminal surfaces and panel key hosts in this window. Hit
/// testing excludes pooled terminals hidden or covered by another destination.
@MainActor
func focusAdjacentPane(_ direction: PaneFocusDirection, window: NSWindow, model: AppModel) -> Bool {
    guard let content = window.contentView, let source = window.firstResponder as? NSView,
          source is JuancodeTerminalResponder || source is PanelKeyView else { return false }
    var views: [NSView] = []
    func collect(_ view: NSView) {
        guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0,
              view.visibleRect.width > 1, view.visibleRect.height > 1 else { return }
        if let panel = view as? PanelKeyView, let target = panel.target {
            if let rail = target.railPanel {
                if model.isRailPanelOpen(rail) { views.append(panel) }
            } else if model.projectsSidebarVisible { views.append(panel) }
        } else if view is JuancodeTerminalResponder {
            let center = view.convert(NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: content.superview)
            if let hit = content.hitTest(center), hit === view || hit.isDescendant(of: view) {
                views.append(view)
            }
        }
        for child in view.subviews { collect(child) }
    }
    collect(content)
    let candidates = views.filter { $0 !== source }
    guard let index = direction.destination(from: source.convert(source.visibleRect, to: nil),
                                            candidates: candidates.map { $0.convert($0.visibleRect, to: nil) })
    else { return true } // An edge is a no-op, never a control byte in the PTY.
    let destination = candidates[index]
    if let panel = destination as? PanelKeyView { return panel.focusForNavigation() }
    return window.makeFirstResponder(destination)
}
