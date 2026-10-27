import AppKit

/// Use AppKit's page-swipe tracking so short/reversed gestures cancel and inertia
/// cannot walk through several sessions. The window bridge owns the monitor.
@MainActor
func installBackForwardSwipe(model: AppModel, oracle: OracleModel, host: NSView) -> Any? {
    let eligible: @MainActor (Int, CGPoint) -> Bool = { [weak host] number, location in
        guard let window = host?.window, window.isKeyWindow,
              window.windowNumber == number, window.attachedSheet == nil,
              let content = window.contentView else { return false }
        // Give wide diffs, editors and other horizontally scrolling content the
        // entire gesture, including when they are already at a scroll boundary.
        var view = content.hitTest(content.convert(location, from: nil))
        while let current = view {
            if let scroll = current as? NSScrollView,
               scroll.hasHorizontalScroller
                || (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width + 1 {
                return false
            }
            view = current.superview
        }
        return true
    }
    let navigate: @MainActor (Bool, Int) -> Void = { [weak host] back, number in
        // Tracking completes asynchronously; a sheet or another window may have
        // taken focus since the gesture started.
        guard let window = host?.window, window.isKeyWindow,
              window.windowNumber == number, window.attachedSheet == nil else { return }
        performShortcut(back ? .navigateBack : .navigateForward, model: model, oracle: oracle)
    }
    return NSEvent.addLocalMonitorForEvents(matching: [.swipe, .scrollWheel]) { event in
        let number = event.windowNumber
        let location = event.locationInWindow
        if event.type == .swipe {
            // Discrete swipes (e.g. the three-finger system preference) use -1
            // for right, unlike natural-scrolling fluid swipe amounts.
            let dx = event.deltaX
            guard dx != 0, abs(dx) > abs(event.deltaY),
                  MainActor.assumeIsolated({ eligible(number, location) }) else { return event }
            MainActor.assumeIsolated { navigate(dx < 0, number) }
            return nil
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.hasPreciseScrollingDeltas, event.phase == .began,
              event.momentumPhase.isEmpty,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5,
              MainActor.assumeIsolated({ eligible(number, location) }) else { return event }
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: -1, max: 1) { amount, phase, complete, _ in
            // AppKit settles at -1/0/1. Zero is a cancelled swipe.
            guard complete, phase != .cancelled, abs(amount) > 0.5 else { return }
            MainActor.assumeIsolated { navigate(amount > 0, number) }
        }
        return nil
    }
}
