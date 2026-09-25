@testable import GhosttyTerminal
import Testing

@MainActor
struct TerminalLifecycleTests {
    @Test
    func `failed surface creation does not retain bridge`() {
        let controller = TerminalController()
        let bridge = TerminalCallbackBridge()

        let surface = controller.createSurface(
            bridge: bridge,
            configuration: .init()
        ) { _ in }

        #expect(surface == nil)
        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `switching controllers removes bridge from old controller`() {
        let oldController = TerminalController()
        let newController = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = oldController
        #expect(oldController.retainedBridgeCount == 0)

        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = newController

        #expect(oldController.retainedBridgeCount == 0)
        #expect(newController.retainedBridgeCount == 0)
    }

    @Test
    func `free surface removes retained bridge`() {
        let controller = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        coordinator.controller = controller

        controller.retain(coordinator.bridge)
        #expect(controller.retainedBridgeCount == 1)

        coordinator.freeSurface()

        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func `wakeup ticks and reaches every surface on a shared controller`() {
        let controller = TerminalController()
        let first = TerminalSurfaceCoordinator()
        let second = TerminalSurfaceCoordinator()
        var reached: [String] = []

        controller.addWakeupObserver(first) { reached.append("first") }
        controller.addWakeupObserver(second) { reached.append("second") }
        controller.handleWakeup()

        #expect(reached.sorted() == ["first", "second"])
    }

    @Test
    func `tearing down one surface keeps the others' wakeups`() {
        let controller = TerminalController()
        let closing = TerminalSurfaceCoordinator()
        let staying = TerminalSurfaceCoordinator()
        var stayingWakeups = 0

        closing.isAttached = { false }
        closing.controller = controller
        controller.addWakeupObserver(closing) {}
        controller.addWakeupObserver(staying) { stayingWakeups += 1 }

        closing.freeSurface()
        controller.handleWakeup()

        #expect(controller.wakeupObserverCount == 1)
        #expect(stayingWakeups == 1)
    }

    @Test
    func `a coordinator that deinits leaves no wakeup behind`() {
        let controller = TerminalController()
        var coordinator: TerminalSurfaceCoordinator? = TerminalSurfaceCoordinator()

        coordinator?.isAttached = { false }
        coordinator?.controller = controller
        controller.addWakeupObserver(coordinator!) {}
        coordinator = nil

        #expect(controller.wakeupObserverCount == 0)
    }

    @Test
    func `application active state controls immediate ticks`() async {
        let coordinator = TerminalSurfaceCoordinator()
        var renders = 0

        coordinator.isAttached = { true }
        coordinator.onPostRender = {
            renders += 1
        }

        coordinator.setApplicationActive(false)
        coordinator.requestImmediateTick()
        await Task.yield()

        #expect(renders == 0)

        coordinator.setApplicationActive(true)
        await Task.yield()

        #expect(renders == 1)
    }
}
