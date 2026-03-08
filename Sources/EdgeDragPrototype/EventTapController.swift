import CoreGraphics

final class EventTapController {
    enum Event {
        case leftMouseDown(CGPoint)
        case leftMouseDragged(CGPoint)
        case leftMouseUp(CGPoint)
        case mouseMoved(CGPoint)
    }

    var onEvent: ((Event) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            controller.dispatch(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap = eventTap else {
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) {
        let location = event.location

        switch type {
        case .leftMouseDown:
            onEvent?(.leftMouseDown(location))
        case .leftMouseDragged:
            onEvent?(.leftMouseDragged(location))
        case .leftMouseUp:
            onEvent?(.leftMouseUp(location))
        case .mouseMoved:
            onEvent?(.mouseMoved(location))
        default:
            break
        }
    }
}
