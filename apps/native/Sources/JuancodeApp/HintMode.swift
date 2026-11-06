// Vimium-style hint mode: press the hint shortcut (⌃F by default), every visible,
// enabled control grows a short letter label, type the label to activate it.
//
// The pieces, from the keyboard outward:
//
// - `HintKeyRouter` decides, for one key-down while hints are up, what happens to
//   it. Nothing is ever handed on to the focused terminal except a ⌘ chord, and
//   that only after hints have been dismissed.
// - `HintSession` / `HintLabels` are the label state: prefix-free labels, narrowing
//   as letters arrive, an exact match activating exactly one target.
// - `HintEngine` runs a session over a fixed list of targets.
// - `HintRegistry` + `HintAnchorView` register controls. A control attaches
//   `.hintTarget { … }` and its own existing activation closure is what runs. Frames
//   and visibility are read lazily, when hints open, so a registered view costs
//   nothing while it lays out and a stale frame cannot exist.
// - `HintController` is the AppKit glue: it collects targets from the registry,
//   draws `HintOverlayView` over the window, and is fed key events by the window
//   key monitor (`installPaneNavigation`).
//
// None of the registration state is observable. SwiftUI never re-renders because a
// control registered, which matters for the toolbar: its owner must stay free of
// observable state (see RootView.swift).

import AppKit
import SwiftUI

// MARK: - Labels and session state (pure)

enum HintLabels {
    /// Home-row first, the Vimium default: the keys you can hit without moving.
    static let alphabet: [Character] = Array("sadfjklewcmpgh")

    /// `count` labels such that none is a prefix of another, so a typed label that
    /// matches is always the whole of exactly one target. Single letters are used
    /// until they run out; then the earliest of them is traded for the two-letter
    /// labels under it. The same construction Vimium uses.
    static func make(count: Int, alphabet: [Character] = HintLabels.alphabet) -> [String] {
        guard count > 0, !alphabet.isEmpty else { return [] }
        var labels = [""]
        var offset = 0
        // Always expand the empty seed at least once, so a lone target still gets a
        // letter to type rather than an empty label.
        while labels.count - offset < count || labels.count == 1 {
            let expanded = labels[offset]
            offset += 1
            for letter in alphabet { labels.append(String(letter) + expanded) }
        }
        // Letters were prepended while expanding, so each label reads backwards: flip
        // them, and every two-letter label starts with the letter that was traded away
        // (which is no longer a label), never with one that still is.
        return labels[offset..<(offset + count)].map { String($0.reversed()) }
    }
}

/// Which label each target carries and how much of one has been typed.
struct HintSession {
    struct Entry: Equatable {
        let index: Int
        let label: String
        let frame: CGRect
    }

    enum Outcome: Equatable {
        /// The letter extended the typed prefix; more than one label still matches.
        case narrowed
        /// The letter completed a label: this target (by index) is the one.
        case activate(Int)
        /// No label continues with this letter, so it changed nothing.
        case ignored
    }

    private(set) var entries: [Entry]
    private(set) var typed = ""

    init(frames: [CGRect], alphabet: [Character] = HintLabels.alphabet) {
        let labels = HintLabels.make(count: frames.count, alphabet: alphabet)
        entries = zip(frames.indices, zip(labels, frames)).map {
            Entry(index: $0, label: $1.0, frame: $1.1)
        }
    }

    /// The entries still reachable from what has been typed.
    var matching: [Entry] { entries.filter { $0.label.hasPrefix(typed) } }

    mutating func type(_ letter: Character) -> Outcome {
        let next = typed + String(letter).lowercased()
        if let hit = entries.first(where: { $0.label == next }) { return .activate(hit.index) }
        guard entries.contains(where: { $0.label.hasPrefix(next) }) else { return .ignored }
        typed = next
        return .narrowed
    }

    mutating func backspace() {
        if !typed.isEmpty { typed.removeLast() }
    }
}

// MARK: - Key routing (pure)

/// What one key-down means while hint mode is up.
enum HintKeyDecision: Equatable {
    /// Hints are not up; the key is not ours.
    case passThrough
    /// Consumed, and changes nothing. Every key that is not a hint letter lands here
    /// rather than falling through to the pty underneath.
    case swallow
    /// Escape, or the hint shortcut again: leave hint mode.
    case cancel
    /// A ⌘ chord is an app command, not hint input: leave hint mode and let the
    /// chord run as it normally would.
    case cancelAndPassThrough
    case backspace
    case type(Character)
}

enum HintKeyRouter {
    static func decide(active: Bool, keyCode: UInt16, characters: String?,
                       modifiers: NSEvent.ModifierFlags, isToggleChord: Bool,
                       alphabet: [Character] = HintLabels.alphabet) -> HintKeyDecision {
        guard active else { return .passThrough }
        if isToggleChord || keyCode == 53 { return .cancel }
        let mods = modifiers.intersection([.command, .shift, .control, .option])
        if mods.contains(.command) { return .cancelAndPassThrough }
        if keyCode == 51 { return .backspace }
        if mods.contains(.control) || mods.contains(.option) { return .swallow }
        if let text = characters?.lowercased(), text.count == 1, let letter = text.first,
           alphabet.contains(letter) {
            return .type(letter)
        }
        return .swallow
    }
}

/// Whether the hint shortcut may open hint mode from where the keyboard is.
///
/// The editor (nvim in a terminal pane) owns every ⌃-key as a vim motion, and
/// ⌃F there is page-down; the window key monitor already hands it all of them but
/// ⌃Tab (see `installPaneNavigation`). A hint shortcut bound to ⌃ follows that rule,
/// so from the editor it is nvim's, and a ⌘ binding still opens hints there. Text
/// fields keep ⌃F as cursor-forward, and the diff review reads its own keys.
enum HintActivation {
    static func allows(modifiers: NSEvent.ModifierFlags, inEditor: Bool,
                       editingText: Bool, reviewActive: Bool) -> Bool {
        let mods = modifiers.intersection([.command, .shift, .control, .option])
        if editingText || reviewActive { return false }
        if inEditor, mods.contains(.control), !mods.contains(.command) { return false }
        return true
    }
}

// MARK: - Engine

/// One hint-mode run over a fixed list of targets, in reading order.
@MainActor
final class HintEngine {
    struct Target {
        let frame: CGRect
        let activate: () -> Void
    }

    struct Step {
        /// The key must not reach anything else.
        var consumed: Bool
        /// Hint mode is over.
        var finished: Bool
        /// The chosen target's own activation, for the caller to run once focus is
        /// back where it was.
        var activation: (() -> Void)?
    }

    private(set) var session: HintSession
    private let targets: [Target]

    init?(targets: [Target]) {
        guard !targets.isEmpty else { return nil }
        self.targets = targets
        session = HintSession(frames: targets.map(\.frame))
    }

    func apply(_ decision: HintKeyDecision) -> Step {
        switch decision {
        case .passThrough:
            return Step(consumed: false, finished: false)
        case .swallow:
            return Step(consumed: true, finished: false)
        case .cancel:
            return Step(consumed: true, finished: true)
        case .cancelAndPassThrough:
            return Step(consumed: false, finished: true)
        case .backspace:
            session.backspace()
            return Step(consumed: true, finished: false)
        case .type(let letter):
            switch session.type(letter) {
            case .activate(let index):
                return Step(consumed: true, finished: true, activation: targets[index].activate)
            case .narrowed, .ignored:
                return Step(consumed: true, finished: false)
            }
        }
    }
}

// MARK: - Geometry (pure)

enum HintGeometry {
    /// A target smaller than this is a sliver left by clipping, not something you
    /// could have clicked.
    static let minimumSide: CGFloat = 4

    /// Whether what is left of `frame` after clipping is worth a label.
    static func isVisible(_ frame: CGRect, within bounds: CGRect) -> Bool {
        let visible = frame.intersection(bounds)
        return !visible.isNull && visible.width >= minimumSide && visible.height >= minimumSide
    }

    /// Reading order for AppKit window coordinates (y grows upward): top row first,
    /// left to right within a row. Rows are 8pt bands so controls that line up
    /// visually sort as one row even when their frames differ by a point.
    static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        let rowA = (a.midY / 8).rounded(), rowB = (b.midY / 8).rounded()
        if rowA != rowB { return rowA > rowB }
        return a.minX < b.minX
    }
}

// MARK: - Registration

/// A control's hint registration. Placed in a SwiftUI view's background it measures
/// the control, and carries the control's own activation closure and enabled state.
@MainActor
final class HintAnchorView: NSView {
    var activate: (() -> Void)?
    var isActionEnabled = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { HintRegistry.shared.remove(self) } else { HintRegistry.shared.add(self) }
    }

    /// Never takes a click: it sits behind a control it does not own.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The control's frame in window coordinates, clipped to every scroll view above
    /// it and to the window — nil when it is not actually on screen.
    func visibleFrameInWindow() -> CGRect? {
        guard let window, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return nil }
        var rect = bounds
        var view: NSView = self
        while let parent = view.superview {
            rect = view.convert(rect, to: parent)
            // A clip view's bounds are the part of its document that is showing.
            if parent is NSClipView { rect = rect.intersection(parent.bounds) }
            if rect.isNull { return nil }
            view = parent
        }
        let inWindow = view.convert(rect, to: nil)
        let windowBounds = CGRect(origin: .zero, size: window.frame.size)
        guard HintGeometry.isVisible(inWindow, within: windowBounds) else { return nil }
        return inWindow.intersection(windowBounds)
    }
}

@MainActor
final class HintRegistry {
    static let shared = HintRegistry()

    private let anchors = NSHashTable<HintAnchorView>.weakObjects()

    func add(_ anchor: HintAnchorView) { anchors.add(anchor) }
    func remove(_ anchor: HintAnchorView) { anchors.remove(anchor) }

    /// Every enabled control currently visible in `window`, in reading order.
    func targets(in window: NSWindow) -> [HintEngine.Target] {
        anchors.allObjects
            .compactMap { anchor -> HintEngine.Target? in
                guard anchor.window === window, anchor.isActionEnabled,
                      let activate = anchor.activate,
                      let frame = anchor.visibleFrameInWindow() else { return nil }
                return HintEngine.Target(frame: frame, activate: activate)
            }
            .sorted { HintGeometry.readingOrder($0.frame, $1.frame) }
    }
}

private struct HintAnchor: NSViewRepresentable {
    let enabled: Bool
    let activate: () -> Void

    func makeNSView(context: Context) -> HintAnchorView { HintAnchorView() }

    func updateNSView(_ view: HintAnchorView, context: Context) {
        view.activate = activate
        // `.disabled(…)` on the control reaches this background through the
        // environment, so a disabled control drops out without a second condition.
        view.isActionEnabled = enabled && context.environment.isEnabled
    }
}

extension View {
    /// Offers this control to hint mode. `activate` is the control's own action, run
    /// when its label is typed. Apply it BEFORE `.disabled(…)` — the environment
    /// flows inward, so only then does the disabled state reach the registration and
    /// leave the control out. `enabled` adds any condition the environment cannot
    /// express.
    func hintTarget(enabled: Bool = true, _ activate: @escaping () -> Void) -> some View {
        background(HintAnchor(enabled: enabled, activate: activate))
    }
}

// MARK: - Controller

/// Owns the one hint session, and the overlay that draws it. Fed by the window key
/// monitor; see `installPaneNavigation`.
@MainActor
final class HintController {
    static let shared = HintController()

    private var engine: HintEngine?
    private weak var window: NSWindow?
    private weak var priorResponder: NSResponder?
    private var overlay: HintOverlayView?
    private var observers: [NSObjectProtocol] = []
    /// Key codes consumed on the way down, whose key-up must not reach the pty
    /// either: a terminal speaking the kitty protocol reports releases.
    private var consumedKeyUps: Set<UInt16> = []

    var isActive: Bool { engine != nil }

    /// Opens hint mode over `window`, or closes it when it is already up.
    func toggle(in window: NSWindow?) {
        if isActive { end(restoreFocus: true); return }
        guard let window else { return }
        begin(in: window)
    }

    func begin(in window: NSWindow, registry: HintRegistry = .shared) {
        guard !isActive, window.attachedSheet == nil,
              let frameView = window.contentView?.superview else { return }
        guard let engine = HintEngine(targets: registry.targets(in: window)) else {
            NSSound.beep()
            return
        }
        self.engine = engine
        self.window = window
        priorResponder = window.firstResponder
        consumedKeyUps.removeAll()

        let overlay = HintOverlayView(frame: frameView.bounds)
        overlay.autoresizingMask = [.width, .height]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.show(engine.session)
        self.overlay = overlay

        // Frames were measured for this window size and key state; anything that
        // changes them ends the session rather than leaving labels on the wrong
        // controls.
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(restoreFocus: false) }
            })
        }
    }

    /// Handles a key-down while hints are up. True when the event must not travel on.
    func handleKeyDown(_ event: NSEvent, isToggleChord: Bool) -> Bool {
        guard let engine, let window else { return false }
        guard window.isKeyWindow, window.attachedSheet == nil else {
            end(restoreFocus: false)
            return false
        }
        // Another window's key (Settings, a sheet's parent) is not hint input.
        if let target = event.window, target !== window { return false }
        let decision = HintKeyRouter.decide(
            active: true, keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags, isToggleChord: isToggleChord)
        let step = engine.apply(decision)
        if step.consumed { consumedKeyUps.insert(event.keyCode) }
        if step.finished {
            end(restoreFocus: true)
            step.activation?()
        } else {
            overlay?.show(engine.session)
        }
        return step.consumed
    }

    /// Whether this key-up belongs to a key-down hint mode consumed.
    func consumesKeyUp(_ keyCode: UInt16) -> Bool {
        isActive || consumedKeyUps.remove(keyCode) != nil
    }

    func end(restoreFocus: Bool) {
        let window = self.window
        let prior = priorResponder
        engine = nil
        self.window = nil
        priorResponder = nil
        overlay?.removeFromSuperview()
        overlay = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        // Back to wherever the keyboard was, before a chosen action runs, so a focus
        // request the action makes itself is not overruled by this one.
        if restoreFocus, let window, let prior, window.firstResponder !== prior,
           (prior as? NSView)?.window === window {
            window.makeFirstResponder(prior)
        }
    }
}

/// Swallows the key-ups of keys hint mode consumed, so nothing underneath sees half a
/// keystroke.
@MainActor
func installHintKeyUpGuard() -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
        let keyCode = event.keyCode
        let consumed = MainActor.assumeIsolated { HintController.shared.consumesKeyUp(keyCode) }
        return consumed ? nil : event
    }
}

// MARK: - Overlay

/// Draws the labels over the whole window, titlebar and toolbar included, and never
/// takes a click or a key.
@MainActor
final class HintOverlayView: NSView {
    private var session: HintSession?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ session: HintSession) {
        self.session = session
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let typedCount = session.typed.count
        for entry in session.matching {
            let rect = convert(entry.frame, from: nil)
            let label = entry.label.uppercased()
            let text = NSMutableAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor.black,
            ])
            // What has been typed is done with: dim it, so the letters still to
            // press stand out.
            text.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.35),
                              range: NSRange(location: 0, length: min(typedCount, label.count)))
            let size = text.size()
            let chip = NSRect(x: rect.minX + 2, y: rect.maxY - size.height - 4,
                              width: size.width + 8, height: size.height + 2)
                .clamped(to: bounds)
            let path = NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3)
            NSColor(calibratedRed: 1, green: 0.87, blue: 0.3, alpha: 0.96).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            text.draw(at: NSPoint(x: chip.minX + 4, y: chip.minY + 1))
        }
    }
}

private extension NSRect {
    /// This rect moved, not resized, to lie inside `outer` where it can.
    func clamped(to outer: NSRect) -> NSRect {
        var moved = self
        moved.origin.x = Swift.min(Swift.max(minX, outer.minX), Swift.max(outer.minX, outer.maxX - width))
        moved.origin.y = Swift.min(Swift.max(minY, outer.minY), Swift.max(outer.minY, outer.maxY - height))
        return moved
    }
}
