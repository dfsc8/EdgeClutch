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
    private let maximumTickDuration: TimeInterval = 1.0 / 45.0
    private let edgeZone: CGFloat = 0.065
    private let directionMemory: CFTimeInterval = 0.18
    private let touchFreshness: CFTimeInterval = 0.12
    private let minimumVelocity: CGFloat = 0.0015
    private let axisDirectionThreshold: CGFloat = 0.2
    private let inwardStopVelocityThreshold: CGFloat = 0.00075
    private let minimumCursorMotionForGestureDrag: CGFloat = 0.5
    private let dragVelocityMemory: CFTimeInterval = 0.25
    private let assistHoldDuration: CFTimeInterval = 0.14
    private let fallbackPixelsPerSecond: CGFloat = 720
    private let continuationVelocityScale: CGFloat = 1.0
    private let maximumContinuationPixelsPerSecond: CGFloat = 820
    private let observedVelocitySmoothing: CGFloat = 0.35
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
            clearAxisContinuations()
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
            holdContinuationsIfNeeded(at: sample.timestamp)
            if pointerState.inferredGestureDrag {
                pointerState.isButtonDown = false
                pointerState.hasDragged = false
                pointerState.inferredGestureDrag = false
            }
            return
        }

        guard supportsTouchCount(sample.touchCount) else {
            if sample.touchCount == 2 || sample.touchCount > 3 {
                clearContinuationState()
            } else {
                holdContinuationsIfNeeded(at: sample.timestamp)
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
        let now = CACurrentMediaTime()
        let xDecision = axisDecision(
            for: .x,
            sample: sample,
            liveDirection: liveDirection,
            rememberedDirection: rememberedDirection,
            pointerDirection: pointerDirection
        )
        let yDecision = axisDecision(
            for: .y,
            sample: sample,
            liveDirection: liveDirection,
            rememberedDirection: rememberedDirection,
            pointerDirection: pointerDirection
        )

        applyAxisDecision(xDecision, to: .x, timestamp: sample.timestamp, now: now)
        applyAxisDecision(yDecision, to: .y, timestamp: sample.timestamp, now: now)
    }

    @objc private func handleTickTimer() {
        tick()
    }

    private func tick() {
        guard pointerState.isButtonDown, pointerState.hasDragged else {
            clearAxisContinuations()
            pointerState.lastTickTime = CACurrentMediaTime()
            return
        }

        let now = CACurrentMediaTime()
        let dt = min(max(0, now - pointerState.lastTickTime), maximumTickDuration)
        pointerState.lastTickTime = now

        guard dt > 0,
              now - assistState.lastTouchTimestamp <= touchFreshness,
              assistState.hasActiveAxes
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

        guard dt > 0, !assistState.hasActiveAxes else {
            return
        }

        let velocity = CGVector(
            dx: (point.x - pointerState.lastDragSamplePosition.x) / dt,
            dy: (point.y - pointerState.lastDragSamplePosition.y) / dt
        )

        guard hypot(velocity.dx, velocity.dy) > 0 else {
            return
        }

        let smoothedVelocity: CGVector
        if pointerState.lastObservedDragVelocity == .zero {
            smoothedVelocity = velocity
        } else {
            smoothedVelocity = CGVector(
                dx: pointerState.lastObservedDragVelocity.dx * (1 - observedVelocitySmoothing) + velocity.dx * observedVelocitySmoothing,
                dy: pointerState.lastObservedDragVelocity.dy * (1 - observedVelocitySmoothing) + velocity.dy * observedVelocitySmoothing
            )
        }

        pointerState.lastObservedDragVelocity = clampVelocityMagnitude(smoothedVelocity, maximum: maximumContinuationPixelsPerSecond)
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
        clearAxisContinuations()
    }

    private func rememberedPointerDirection(at now: CFTimeInterval) -> CGVector {
        normalizedVector(for: rememberedDragVelocity(at: now))
    }

    private func seedContinuationVelocityComponent(for axis: Axis, edgeSide: EdgeSide, now: CFTimeInterval) -> CGFloat {
        let rememberedComponent = axis.component(of: rememberedDragVelocity(at: now))
        let outwardSign = edgeSide.outwardSign

        if rememberedComponent != 0, rememberedComponent.sign == outwardSign {
            return min(abs(rememberedComponent) * continuationVelocityScale, maximumContinuationPixelsPerSecond) * outwardSign
        }

        return min(fallbackPixelsPerSecond, maximumContinuationPixelsPerSecond) * outwardSign
    }

    private func axisDecision(
        for axis: Axis,
        sample: TouchpadMonitor.Sample,
        liveDirection: CGVector,
        rememberedDirection: CGVector,
        pointerDirection: CGVector
    ) -> AxisContinuationDecision {
        let currentEdge = touchedEdge(for: axis, sample: sample)
        guard let edgeSide = currentEdge.edgeSide else {
            return .hold
        }

        let directionComponent = preferredDirectionComponent(
            live: axis.component(of: liveDirection),
            remembered: axis.component(of: rememberedDirection),
            pointer: axis.component(of: pointerDirection)
        )
        let velocityComponent = axis.component(of: sample.velocity)

        if isOutward(directionComponent, for: edgeSide, threshold: axisDirectionThreshold) {
            return .activate(edgeSide: edgeSide, strength: edgeStrength(position: currentEdge.position, velocity: velocityComponent, edge: edgeSide))
        }

        if isInward(velocityComponent, for: edgeSide, threshold: inwardStopVelocityThreshold)
            || isInward(directionComponent, for: edgeSide, threshold: axisDirectionThreshold) {
            return .stop
        }

        return .hold
    }

    private func applyAxisDecision(_ decision: AxisContinuationDecision, to axis: Axis, timestamp: CFTimeInterval, now: CFTimeInterval) {
        var state = axisState(for: axis)

        switch decision {
        case .activate(let edgeSide, let strength):
            let shouldSeedVelocity = !state.isActive || state.edgeSide != edgeSide || axis.component(of: assistState.continuationVelocity) == 0
            state.edgeSide = edgeSide
            state.strength = strength
            state.lastActiveTimestamp = timestamp
            setAxisState(state, for: axis)

            if shouldSeedVelocity {
                setContinuationVelocityComponent(
                    seedContinuationVelocityComponent(for: axis, edgeSide: edgeSide, now: now),
                    for: axis
                )
            }
        case .hold:
            if state.isActive, timestamp - state.lastActiveTimestamp <= assistHoldDuration {
                return
            }
            clearAxisContinuation(axis)
        case .stop:
            clearAxisContinuation(axis)
        }
    }

    private func holdContinuationsIfNeeded(at timestamp: CFTimeInterval) {
        if assistState.xAxis.isActive, timestamp - assistState.xAxis.lastActiveTimestamp > assistHoldDuration {
            clearAxisContinuation(.x)
        }

        if assistState.yAxis.isActive, timestamp - assistState.yAxis.lastActiveTimestamp > assistHoldDuration {
            clearAxisContinuation(.y)
        }
    }

    private func clearAxisContinuations() {
        clearAxisContinuation(.x)
        clearAxisContinuation(.y)
    }

    private func clearAxisContinuation(_ axis: Axis) {
        var state = axisState(for: axis)
        state.clear()
        setAxisState(state, for: axis)
        setContinuationVelocityComponent(0, for: axis)
    }

    private func axisState(for axis: Axis) -> AxisContinuationState {
        switch axis {
        case .x:
            return assistState.xAxis
        case .y:
            return assistState.yAxis
        }
    }

    private func setAxisState(_ state: AxisContinuationState, for axis: Axis) {
        switch axis {
        case .x:
            assistState.xAxis = state
        case .y:
            assistState.yAxis = state
        }
    }

    private func setContinuationVelocityComponent(_ value: CGFloat, for axis: Axis) {
        switch axis {
        case .x:
            assistState.continuationVelocity.dx = value
        case .y:
            assistState.continuationVelocity.dy = value
        }
    }

    private func touchedEdge(for axis: Axis, sample: TouchpadMonitor.Sample) -> AxisEdgeSample {
        switch axis {
        case .x:
            if sample.minTouch.x <= edgeZone {
                return AxisEdgeSample(edgeSide: .minimum, position: sample.minTouch.x)
            }
            if sample.maxTouch.x >= 1 - edgeZone {
                return AxisEdgeSample(edgeSide: .maximum, position: sample.maxTouch.x)
            }
        case .y:
            if sample.minTouch.y <= edgeZone {
                return AxisEdgeSample(edgeSide: .minimum, position: sample.minTouch.y)
            }
            if sample.maxTouch.y >= 1 - edgeZone {
                return AxisEdgeSample(edgeSide: .maximum, position: sample.maxTouch.y)
            }
        }

        return AxisEdgeSample(edgeSide: nil, position: 0)
    }

    private func preferredDirectionComponent(live: CGFloat, remembered: CGFloat, pointer: CGFloat) -> CGFloat {
        if abs(live) >= axisDirectionThreshold {
            return live
        }

        if abs(remembered) >= axisDirectionThreshold {
            return remembered
        }

        if abs(pointer) >= axisDirectionThreshold {
            return pointer
        }

        return 0
    }

    private func isOutward(_ component: CGFloat, for edgeSide: EdgeSide, threshold: CGFloat) -> Bool {
        component * edgeSide.outwardSign >= threshold
    }

    private func isInward(_ component: CGFloat, for edgeSide: EdgeSide, threshold: CGFloat) -> Bool {
        component * edgeSide.outwardSign <= -threshold
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

    private func clampVelocityMagnitude(_ velocity: CGVector, maximum: CGFloat) -> CGVector {
        let magnitude = hypot(velocity.dx, velocity.dy)
        guard magnitude > 0, magnitude > maximum else {
            return velocity
        }

        let scale = maximum / magnitude
        return CGVector(dx: velocity.dx * scale, dy: velocity.dy * scale)
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
    var continuationVelocity = CGVector.zero
    var lastDirection = CGVector.zero
    var lastDirectionTimestamp: CFTimeInterval = 0
    var lastTouchTimestamp: CFTimeInterval = 0
    var currentTouchCount = 0
    var xAxis = AxisContinuationState()
    var yAxis = AxisContinuationState()

    var hasActiveAxes: Bool {
        xAxis.isActive || yAxis.isActive
    }
}

private enum ContinuationMode {
    case mouseDrag
    case cursorMove
}

private enum Axis {
    case x
    case y

    func component(of vector: CGVector) -> CGFloat {
        switch self {
        case .x:
            return vector.dx
        case .y:
            return vector.dy
        }
    }
}

private enum EdgeSide {
    case minimum
    case maximum

    var outwardSign: CGFloat {
        switch self {
        case .minimum:
            return -1
        case .maximum:
            return 1
        }
    }
}

private enum AxisContinuationDecision {
    case activate(edgeSide: EdgeSide, strength: CGFloat)
    case hold
    case stop
}

private struct AxisEdgeSample {
    let edgeSide: EdgeSide?
    let position: CGFloat
}

private struct AxisContinuationState {
    var edgeSide: EdgeSide?
    var strength: CGFloat = 0
    var lastActiveTimestamp: CFTimeInterval = 0

    var isActive: Bool {
        edgeSide != nil && strength > 0
    }

    mutating func clear() {
        edgeSide = nil
        strength = 0
        lastActiveTimestamp = 0
    }
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
