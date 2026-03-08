import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class TouchpadMonitor {
    struct Sample {
        let centroid: CGPoint
        let velocity: CGVector
        let touchCount: Int
        let minTouch: CGPoint
        let maxTouch: CGPoint
        let timestamp: CFTimeInterval
    }

    var onSample: ((Sample) -> Void)?

    private var api: MultitouchAPI?
    private var devices: [MTDevice] = []
    private var isRunning = false

    var running: Bool {
        isRunning
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            return true
        }

        guard let api = MultitouchAPI.load() else {
            return false
        }

        self.api = api
        TouchpadMonitorRegistry.monitor = self

        let deviceArray = api.deviceCreateList().takeRetainedValue()
        let count = CFArrayGetCount(deviceArray)
        guard count > 0 else {
            return false
        }

        var collectedDevices: [MTDevice] = []
        collectedDevices.reserveCapacity(count)

        for index in 0..<count {
            let rawValue = CFArrayGetValueAtIndex(deviceArray, index)
            let device = unsafeBitCast(rawValue, to: MTDevice.self)
            collectedDevices.append(device)
            api.registerContactFrameCallback(device, multitouchCallback)
            api.deviceStart(device, 0)
        }

        devices = collectedDevices
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning, let api else {
            return
        }

        let devicesToStop = devices
        devices.removeAll()
        isRunning = false

        for device in devicesToStop {
            api.unregisterContactFrameCallback(device, multitouchCallback)
        }

        let deviceHandles = devicesToStop.map { UInt(bitPattern: $0) }

        // Empirically, the private framework can race if stop follows unregister immediately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for handle in deviceHandles {
                guard let device = UnsafeMutableRawPointer(bitPattern: handle) else {
                    continue
                }
                api.deviceStop(device)
            }
        }

        TouchpadMonitorRegistry.monitor = nil
    }

    nonisolated fileprivate func handleCallback(contacts: UnsafePointer<MTTouch>?, count: Int, timestamp: Double) {
        guard count > 0, let contacts else {
            Task { @MainActor [weak self] in
                self?.onSample?(Sample(
                    centroid: .zero,
                    velocity: .zero,
                    touchCount: 0,
                    minTouch: .zero,
                    maxTouch: .zero,
                    timestamp: timestamp
                ))
            }
            return
        }

        var centroid = CGPoint.zero
        var velocity = CGVector.zero
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for index in 0..<count {
            let touch = contacts[index]
            let positionX = CGFloat(touch.normalized.position.x)
            let positionY = CGFloat(touch.normalized.position.y)

            centroid.x += positionX
            centroid.y += positionY
            velocity.dx += CGFloat(touch.normalized.velocity.x)
            velocity.dy += CGFloat(touch.normalized.velocity.y)
            minX = min(minX, positionX)
            maxX = max(maxX, positionX)
            minY = min(minY, positionY)
            maxY = max(maxY, positionY)
        }

        let divisor = CGFloat(count)
        let sample = Sample(
            centroid: CGPoint(x: centroid.x / divisor, y: centroid.y / divisor),
            velocity: CGVector(dx: velocity.dx / divisor, dy: -(velocity.dy / divisor)),
            touchCount: count,
            minTouch: CGPoint(x: minX, y: minY),
            maxTouch: CGPoint(x: maxX, y: maxY),
            timestamp: timestamp
        )

        let flippedSample = Sample(
            centroid: CGPoint(x: sample.centroid.x, y: 1 - sample.centroid.y),
            velocity: sample.velocity,
            touchCount: sample.touchCount,
            minTouch: CGPoint(x: sample.minTouch.x, y: 1 - sample.maxTouch.y),
            maxTouch: CGPoint(x: sample.maxTouch.x, y: 1 - sample.minTouch.y),
            timestamp: sample.timestamp
        )

        Task { @MainActor [weak self] in
            self?.onSample?(flippedSample)
        }
    }
}

private typealias MTDevice = UnsafeMutableRawPointer
private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>
private typealias MTRegisterContactFrameCallback = @convention(c) (MTDevice, MTContactCallback) -> Void
private typealias MTUnregisterContactFrameCallback = @convention(c) (MTDevice, MTContactCallback) -> Void
private typealias MTDeviceStart = @convention(c) (MTDevice, Int32) -> Void
private typealias MTDeviceStop = @convention(c) (MTDevice) -> Void
private typealias MTContactCallback = @convention(c) (MTDevice, UnsafeMutableRawPointer, Int32, Double, Int32) -> Int32

private struct MultitouchAPI: @unchecked Sendable {
    let deviceCreateList: MTDeviceCreateList
    let registerContactFrameCallback: MTRegisterContactFrameCallback
    let unregisterContactFrameCallback: MTUnregisterContactFrameCallback
    let deviceStart: MTDeviceStart
    let deviceStop: MTDeviceStop

    static func load() -> MultitouchAPI? {
        let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport"

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            return nil
        }

        guard let deviceCreateList = symbol(named: "MTDeviceCreateList", in: handle, as: MTDeviceCreateList.self),
              let registerContactFrameCallback = symbol(named: "MTRegisterContactFrameCallback", in: handle, as: MTRegisterContactFrameCallback.self),
              let unregisterContactFrameCallback = symbol(named: "MTUnregisterContactFrameCallback", in: handle, as: MTUnregisterContactFrameCallback.self),
              let deviceStart = symbol(named: "MTDeviceStart", in: handle, as: MTDeviceStart.self),
              let deviceStop = symbol(named: "MTDeviceStop", in: handle, as: MTDeviceStop.self)
        else {
            dlclose(handle)
            return nil
        }

        return MultitouchAPI(
            deviceCreateList: deviceCreateList,
            registerContactFrameCallback: registerContactFrameCallback,
            unregisterContactFrameCallback: unregisterContactFrameCallback,
            deviceStart: deviceStart,
            deviceStop: deviceStop
        )
    }

    private static func symbol<T>(named name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let rawSymbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(rawSymbol, to: type)
    }
}

private enum TouchpadMonitorRegistry {
    nonisolated(unsafe) static var monitor: TouchpadMonitor?
}

private let multitouchCallback: MTContactCallback = { _, contacts, count, timestamp, _ in
    let touchPointer = UnsafeRawPointer(contacts).assumingMemoryBound(to: MTTouch.self)
    TouchpadMonitorRegistry.monitor?.handleCallback(contacts: touchPointer, count: Int(count), timestamp: timestamp)
    return 0
}

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4: MTVector
    var unknown5_1: Int32
    var unknown5_2: Int32
    var unknown6: Float
}
