import AppKit

/// Directional pane focus shared by Ctrl-H/J/K/L and the user's tmux Alt-arrows.
enum PaneFocusDirection: CaseIterable {
    case left, down, up, right

    static func matching(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                         reviewActive: Bool = false, editingText: Bool = false,
                         editorFocused: Bool = false) -> Self? {
        guard !reviewActive, !editingText else { return nil }
        let mods = modifiers.intersection([.command, .control, .option, .shift])
        if mods == .control {
            guard !editorFocused else { return nil }
            return [4: .left, 38: .down, 40: .up, 37: .right][keyCode]
        }
        if mods == .option {
            return [123: .left, 125: .down, 126: .up, 124: .right][keyCode]
        }
        return nil
    }

    /// Prefer panes overlapping the source on the perpendicular axis, then distance.
    /// AppKit coordinates here are in the window, with y increasing upward.
    func destination(from source: CGRect, candidates: [CGRect]) -> Int? {
        var best: (index: Int, score: CGFloat)?
        for (index, frame) in candidates.enumerated() {
            let forward: CGFloat
            let cross: CGFloat
            let overlaps: Bool
            switch self {
            case .left, .right:
                guard self == .left ? frame.maxX <= source.minX + 4 : frame.minX >= source.maxX - 4 else { continue }
                forward = (frame.midX - source.midX) * (self == .left ? -1 : 1)
                cross = abs(frame.midY - source.midY)
                overlaps = frame.minY < source.maxY && frame.maxY > source.minY
            case .down, .up:
                guard self == .down ? frame.maxY <= source.minY + 4 : frame.minY >= source.maxY - 4 else { continue }
                forward = (frame.midY - source.midY) * (self == .down ? -1 : 1)
                cross = abs(frame.midX - source.midX)
                overlaps = frame.minX < source.maxX && frame.maxX > source.minX
            }
            guard forward > 1 else { continue }
            let score = forward + cross + (overlaps ? 0 : 100_000)
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best?.index
    }
}
