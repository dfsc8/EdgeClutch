import AppKit
import CoreGraphics
import QuartzCore

@MainActor
final class DragAssistController: NSObject {
    struct GestureSettings {
        var singleFingerEnabled: Bool
        var threeFingerEnabled: Bool
    }

    struct RuntimeStatus {
        let eventTapRunning: Bool
        let touchMonitorRunning: Bool
    }

    private let eventTapController = EventTapController()
    private let touchpadMonitor = TouchpadMonitor()
    private var pointerState = PointerState()
    private var assistState = AssistState()
    private var ticker: Timer?

    private let tickInterval: TimeInterval = 1.0 / 120.0
    private let edgeZone: CGFloat = 0.065
    private let directionMemory: CFTimeInterval = 0.18
    private let touchFreshness: CFTimeInterval = 0.12
    private let minimumVelocity: CGFloat = 0.0015
    private let minimumCursorMotionForGestureDrag: CGFloat = 0.5
    private let dragVelocityMemory: CFTimeInterval = 0.25
    private let assistHoldDuration: CFTimeInterval = 0.14
    private let fallbackPixelsPerSecond: CGFloat = 720
    private let continuationVelocityScale: CGFloat = 1.0
    private var gestureSettings = GestureSettings(singleFingerEnabled: true, threeFingerEnabled: true)

    override init() {
        super.init()

        eventTapController.onEvent = { [weak self] event in
            self?.handle(event: event)
        }

        touchpadMonitor.onSample = { [weak self] sample in
            self?.handle(sample: sample)
        }
    }

    func start() -> RuntimeStatus {
        let eventTapRunning = eventTapController.start()
        let touchMonitorRunning = touchpadMonitor.start()
        startTickerIfNeeded()
        return RuntimeStatus(eventTapRunning: eventTapRunning, touchMonitorRunning: touchMonitorRunning)
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        eventTapController.stop()
        touchpadMonitor.stop()
        resetState()
    }

    func runtimeStatus() -> RuntimeStatus {
        RuntimeStatus(
            eventTapRunning: eventTapController.isRunning,
            touchMonitorRunning: touchpadMonitor.running
        )
    }

    func updateGestureSettings(_ settings: GestureSettings) {
        gestureSettings = settings

        if !supportsTouchCount(assistState.currentTouchCount) {
            clearContinuationState()
        }
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else {
            return
        }

        let timer = Timer.scheduledTimer(timeInterval: tickInterval, target: self, selector: #selector(handleTickTimer), userInfo: nil, repeats: true)
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetState() {
        pointerState = PointerState()
        assistState = AssistState()
    }

    private func handle(event: EventTapController.Event) {
        switch event {
        case .leftMouseDown(let point):
            beginDragTracking(at: point, isDraggedEvent: false)
            pointerState.inferredGestureDrag = false
            pointerState.continuationMode = .mouseDrag
            assistState.activeVector = .zero
        case .leftMouseDragged(let point):
            if !pointerState.isButtonDown {
                beginDragTracking(at: point, isDraggedEvent: true)
            }
            updateObservedDragVelocity(at: point)
            pointerState.isButtonDown = true
            pointerState.hasDragged = true
            pointerState.inferredGestureDrag = false
            pointerState.continuationMode = .mouseDrag
            pointerState.lastCursorPosition = point
        case .leftMouseUp(let point):
            clearContinuationState()
            pointerState.lastCursorPosition = point
        case .mouseMoved(let point):
            handleMouseMoved(at: point)
        }
    }

    private func beginDragTracking(at point: CGPoint, isDraggedEvent: Bool) {
        pointerState.isButtonDown = true
        pointerState.hasDragged = isDraggedEvent
        pointerState.lastCursorPosition = point
        let now = CACurrentMediaTime()
        pointerState.lastTickTime = now
        pointerState.lastDragSamplePosition = point
        pointerState.lastDragSampleTime = now
        pointerState.lastObservedDragVelocity = .zero
        pointerState.lastObservedDragTimestamp = 0
    }

    private func handleMouseMoved(at point: CGPoint) {
        let delta = CGVector(
            dx: point.x - pointerState.lastCursorPosition.x,
            dy: point.y - pointerState.lastCursorPosition.y
        )
        let distance = hypot(delta.dx, delta.dy)

        defer {
            pointerState.lastCursorPosition = point
        }

        guard gestureSettings.threeFingerEnabled, assistState.currentTouchCount == 3 else {
            return
        }

        if !pointerState.inferredGestureDrag {
            guard distance >= minimumCursorMotionForGestureDrag else {
                return
            }
            beginDragTracking(at: point, isDraggedEvent: true)
            pointerState.inferredGestureDrag = true
            pointerState.continuationMode = .cursorMove
            return
        }

        updateObservedDragVelocity(at: point)
        pointerState.isButtonDown = true
        pointerState.hasDragged = true
    }

    private func handle(sample: TouchpadMonitor.Sample) {
        assistState.lastTouchTimestamp = sample.timestamp
        assistState.currentTouchCount = sample.touchCount

        guard sample.touchCount > 0 else {
            if sample.timestamp - assistState.lastActiveVectorTimestamp > assistHoldDuration {
                assistState.activeVector = .zero
                assistState.continuationVelocity = .zero
            }
            if pointerState.inferredGestureDrag {
                pointerState.isButtonDown = false
                pointerState.hasDragged = false
                pointerState.inferredGestureDrag = false
            }
            return
        }

        guard supportsTouchCount(sample.touchCount) else {
            if sample.timestamp - assistState.lastActiveVectorTimestamp > assistHoldDuration {
                assistState.activeVector = .zero
                assistState.continuationVelocity = .zero
            }
            if sample.touchCount == 2 || sample.touchCount > 3 {
                clearContinuationState()
            }
            return
        }

        let liveDirection = normalizedVector(for: sample.velocity)
        if liveDirection != .zero {
            assistState.lastDirection = liveDirection
            assistState.lastDirectionTimestamp = sample.timestamp
        }

        let rememberedDirection: CGVector
        if sample.timestamp - assistState.lastDirectionTimestamp <= directionMemory {
            rememberedDirection = assistState.lastDirection
        } else {
            rememberedDirection = .zero
        }

        let pointerDirection = rememberedPointerDirection(at: CACurrentMediaTime())
        let candidate = assistVector(
            for: sample,
            rememberedDirection: rememberedDirection,
            pointerDirection: pointerDirection
        )

        if candidate != .zero {
            if assistState.activeVector == .zero {
                assistState.continuationVelocity = seedContinuationVelocity(for: candidate, now: CACurrentMediaTime())
            }
            assistState.activeVector = candidate
            assistState.lastActiveVector = candidate
            assistState.lastActiveVectorTimestamp = sample.timestamp
        } else if sample.timestamp - assistState.lastActiveVectorTimestamp <= assistHoldDuration {
            assistState.activeVector = assistState.lastActiveVector
        } else {
            assistState.activeVector = .zero
            assistState.continuationVelocity = .zero
        }
    }

    @objc private func handleTickTimer() {
        tick()
    }

    private func tick() {
        guard pointerState.isButtonDown, pointerState.hasDragged else {
            assistState.activeVector = .zero
            pointerState.lastTickTime = CACurrentMediaTime()
            return
        }

        let now = CACurrentMediaTime()
        let dt = max(0, now - pointerState.lastTickTime)
        pointerState.lastTickTime = now

        guard dt > 0,
              now - assistState.lastTouchTimestamp <= touchFreshness,
              assistState.activeVector != .zero
        else {
            return
        }

        let continuationVelocity = assistState.continuationVelocity
        let delta = CGPoint(
            x: continuationVelocity.dx * dt,
            y: continuationVelocity.dy * dt
        )

        guard delta != .zero else {
            return
        }

        let nextPoint = clampToDesktopBounds(pointerState.lastCursorPosition.applying(delta))
        guard nextPoint != pointerState.lastCursorPosition else {
            return
        }

        postContinuationEvent(to: nextPoint, mode: pointerState.continuationMode)
        pointerState.lastCursorPosition = nextPoint
    }

    private func updateObservedDragVelocity(at point: CGPoint) {
        let now = CACurrentMediaTime()
        let dt = now - pointerState.lastDragSampleTime

        defer {
            pointerState.lastDragSamplePosition = point
            pointerState.lastDragSampleTime = now
        }

        guard dt > 0, assistState.activeVector == .zero else {
            return
        }

        let velocity = CGVector(
            dx: (point.x - pointerState.lastDragSamplePosition.x) / dt,
            dy: (point.y - pointerState.lastDragSamplePosition.y) / dt
        )

        guard hypot(velocity.dx, velocity.dy) > 0 else {
            return
        }

        pointerState.lastObservedDragVelocity = velocity
        pointerState.lastObservedDragTimestamp = now
    }

    private func rememberedDragVelocity(at now: CFTimeInterval) -> CGVector {
        guard now - pointerState.lastObservedDragTimestamp <= dragVelocityMemory else {
            return .zero
        }

        return pointerState.lastObservedDragVelocity
    }

    private func supportsTouchCount(_ touchCount: Int) -> Bool {
        switch touchCount {
        case 1:
            return gestureSettings.singleFingerEnabled
        case 3:
            return gestureSettings.threeFingerEnabled
        default:
            return false
        }
    }

    private func clearContinuationState() {
        pointerState.isButtonDown = false
        pointerState.hasDragged = false
        pointerState.inferredGestureDrag = false
        pointerState.continuationMode = .mouseDrag
        pointerState.lastObservedDragVelocity = .zero
        pointerState.lastObservedDragTimestamp = 0
        assistState.activeVector = .zero
        assistState.continuationVelocity = .zero
    }

    private func rememberedPointerDirection(at now: CFTimeInterval) -> CGVector {
        normalizedVector(for: rememberedDragVelocity(at: now))
    }

    private func seedContinuationVelocity(for vector: CGVector, now: CFTimeInterval) -> CGVector {
        let rememberedVelocity = rememberedDragVelocity(at: now)
        if rememberedVelocity != .zero {
            return CGVector(
                dx: rememberedVelocity.dx * continuationVelocityScale,
                dy: rememberedVelocity.dy * continuationVelocityScale
            )
        }

        return CGVector(
            dx: fallbackVelocityInPixels(for: vector.dx),
            dy: fallbackVelocityInPixels(for: vector.dy)
        )
    }

    private func assistVector(
        for sample: TouchpadMonitor.Sample,
        rememberedDirection: CGVector,
        pointerDirection: CGVector
    ) -> CGVector {
        var output = CGVector.zero

        let liveDirection = normalizedVector(for: sample.velocity)
        let direction: CGVector
        if liveDirection != .zero {
            direction = liveDirection
        } else if rememberedDirection != .zero {
            direction = rememberedDirection
        } else {
            direction = pointerDirection
        }

        if sample.minTouch.x <= edgeZone, direction.dx < -0.2 {
            output.dx = -edgeStrength(position: sample.minTouch.x, velocity: sample.velocity.dx, edge: .minimum)
        } else if sample.maxTouch.x >= 1 - edgeZone, direction.dx > 0.2 {
            output.dx = edgeStrength(position: sample.maxTouch.x, velocity: sample.velocity.dx, edge: .maximum)
        }

        if sample.minTouch.y <= edgeZone, direction.dy < -0.2 {
            output.dy = -edgeStrength(position: sample.minTouch.y, velocity: sample.velocity.dy, edge: .minimum)
        } else if sample.maxTouch.y >= 1 - edgeZone, direction.dy > 0.2 {
            output.dy = edgeStrength(position: sample.maxTouch.y, velocity: sample.velocity.dy, edge: .maximum)
        }

        return output
    }

    private func edgeStrength(position: CGFloat, velocity: CGFloat, edge: EdgeSide) -> CGFloat {
        let depth: CGFloat
        switch edge {
        case .minimum:
            depth = max(0, (edgeZone - position) / edgeZone)
        case .maximum:
            depth = max(0, (position - (1 - edgeZone)) / edgeZone)
        }

        let speed = min(abs(velocity) / 0.02, 1)
        return min(max(depth, speed, 0.35), 1)
    }

    private func normalizedVector(for vector: CGVector) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude >= minimumVelocity else {
            return .zero
        }

        return CGVector(dx: vector.dx / magnitude, dy: vector.dy / magnitude)
    }

    private func fallbackVelocityInPixels(for axisStrength: CGFloat) -> CGFloat {
        guard axisStrength != 0 else {
            return 0
        }

        return fallbackPixelsPerSecond * axisStrength.sign
    }

    private func postContinuationEvent(to point: CGPoint, mode: ContinuationMode) {
        switch mode {
        case .mouseDrag:
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return
            }
            event.post(tap: .cghidEventTap)
        case .cursorMove:
            CGWarpMouseCursorPosition(point)
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                return
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func clampToDesktopBounds(_ point: CGPoint) -> CGPoint {
        let desktopBounds = NSScreen.screens.reduce(into: CGRect.null) { partial, screen in
            partial = partial.union(screen.frame)
        }

        guard !desktopBounds.isNull else {
            return point
        }

        return CGPoint(
            x: min(max(point.x, desktopBounds.minX), desktopBounds.maxX - 1),
            y: min(max(point.y, desktopBounds.minY), desktopBounds.maxY - 1)
        )
    }
}

private struct PointerState {
    var isButtonDown = false
    var hasDragged = false
    var inferredGestureDrag = false
    var continuationMode: ContinuationMode = .mouseDrag
    var lastCursorPosition = CGPoint.zero
    var lastTickTime = CACurrentMediaTime()
    var lastDragSamplePosition = CGPoint.zero
    var lastDragSampleTime = CACurrentMediaTime()
    var lastObservedDragVelocity = CGVector.zero
    var lastObservedDragTimestamp: CFTimeInterval = 0
}

private struct AssistState {
    var activeVector = CGVector.zero
    var continuationVelocity = CGVector.zero
    var lastDirection = CGVector.zero
    var lastDirectionTimestamp: CFTimeInterval = 0
    var lastTouchTimestamp: CFTimeInterval = 0
    var currentTouchCount = 0
    var lastActiveVector = CGVector.zero
    var lastActiveVectorTimestamp: CFTimeInterval = 0
}

private enum ContinuationMode {
    case mouseDrag
    case cursorMove
}

private enum EdgeSide {
    case minimum
    case maximum
}

private extension CGPoint {
    func applying(_ delta: CGPoint) -> CGPoint {
        CGPoint(x: x + delta.x, y: y + delta.y)
    }
}

private extension CGFloat {
    var sign: CGFloat {
        self >= 0 ? 1 : -1
    }
}
