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
                .frame(width: 0, height: 0)
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

private final class PanelKeyView: NSView {
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
    override func resignFirstResponder() -> Bool {
        if model?.panelNavigation.target == target {
            model?.panelNavigation.end()
            model?.suppressTerminalAutoFocus = false
        }
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard let model, window?.attachedSheet == nil,
              !model.changesKeyboardActive, !model.showingDiffReview,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { super.keyDown(with: event); return }
        if event.keyCode == 53 { model.focusTerminal(); return }
        if !model.panelNavigation.handle(event.keyCode) { super.keyDown(with: event) }
    }
}
