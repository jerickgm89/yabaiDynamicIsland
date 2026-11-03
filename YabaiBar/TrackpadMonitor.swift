import AppKit
import os

// Los dedos sobre el trackpad en cualquier app, para el gesto de 3 o 4 dedos hacia abajo. macOS no tiene API
// pública para gestos de 3 o 4 dedos fuera de las ventanas propias (son del Dock), así que se leen con
// MultitouchSupport, un framework privado de Apple que también usan BetterTouchTool o MiddleClick. No pide
// permisos. Si una versión de macOS lo quita o lo cambia, el gesto deja de funcionar y queda el atajo ⌥I.
@MainActor
final class TrackpadMonitor {
    private let api = MultitouchAPI()
    /// La lista mantiene vivos los dispositivos mientras se escuchan
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var wakeObserver: NSObjectProtocol?

    init(onSwipeDown: @escaping @MainActor @Sendable () -> Void) {
        touchState.setHandler(onSwipeDown)
        start()
        // Tras el reposo, MultitouchSupport deja de mandar los toques: se vuelve a empezar, y de paso se ven los
        // trackpads conectados mientras tanto
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
                self?.start()
            }
        }
    }

    private func start() {
        guard let api else {
            Logger.app.error("Trackpad: MultitouchSupport no está disponible; el gesto no funcionará")
            return
        }
        guard let list = api.createList()?.takeRetainedValue() else { return }
        deviceList = list
        devices = (0..<CFArrayGetCount(list)).compactMap { index in
            CFArrayGetValueAtIndex(list, index).map { UnsafeMutableRawPointer(mutating: $0) }
        }
        for device in devices {
            api.register(device, contactFrame)
            api.start(device, 0)
        }
        Logger.app.info("Trackpad: escuchando \(self.devices.count) dispositivos")
    }

    private func stop() {
        guard let api else { return }
        for device in devices {
            api.unregister(device, contactFrame)
            api.stop(device)
        }
        devices = []
        deviceList = nil
    }
}

private typealias ContactCallback = @convention(c) (
    _ device: UnsafeMutableRawPointer?, _ touches: UnsafeRawPointer?, _ count: Int32, _ timestamp: Double, _ frame: Int32
) -> Int32

// Las funciones de MultitouchSupport, cargadas con dlopen: no se enlaza el framework privado
private struct MultitouchAPI {
    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    let unregister: @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Void

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let library = dlopen(path, RTLD_NOW),
              let createList = dlsym(library, "MTDeviceCreateList"),
              let register = dlsym(library, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(library, "MTUnregisterContactFrameCallback"),
              let start = dlsym(library, "MTDeviceStart"),
              let stop = dlsym(library, "MTDeviceStop") else { return nil }
        self.createList = unsafeBitCast(createList, to: (@convention(c) () -> Unmanaged<CFArray>?).self)
        self.register = unsafeBitCast(register, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        self.unregister = unsafeBitCast(unregister, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        self.start = unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        self.stop = unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
    }
}

// Cada toque es una estructura de C de 96 bytes; solo se leen el estado y la posición normalizada
private enum TouchLayout {
    static let stride = 96
    static let stateOffset = 20
    static let xOffset = 32
    static let yOffset = 36
    /// Estados 3 (empieza a tocar) y 4 (tocando): los dedos que se acercan o se levantan no cuentan
    static let touchingStates: ClosedRange<Int32> = 3...4
}

// El detector y el aviso, compartidos con el hilo de MultitouchSupport: una función de C no captura contexto
private final class TouchState: Sendable {
    private struct State {
        var detector = FingerSwipeDetector()
        var handler: (@MainActor @Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { $0.handler = handler }
    }

    func track(_ fingers: [FingerSwipeDetector.Finger]) {
        let handler = state.withLock { $0.detector.track(fingers) ? $0.handler : nil }
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}

private let touchState = TouchState()

// MultitouchSupport llama desde su propio hilo, una vez por fotograma mientras hay dedos en el trackpad
private func contactFrame(
    _ device: UnsafeMutableRawPointer?, _ touches: UnsafeRawPointer?, _ count: Int32, _ timestamp: Double, _ frame: Int32
) -> Int32 {
    guard let touches else { return 0 }
    let fingers = (0..<Int(max(count, 0))).compactMap { position -> FingerSwipeDetector.Finger? in
        let touch = touches + position * TouchLayout.stride
        guard TouchLayout.touchingStates.contains(touch.load(fromByteOffset: TouchLayout.stateOffset, as: Int32.self)) else {
            return nil
        }
        return FingerSwipeDetector.Finger(
            x: touch.load(fromByteOffset: TouchLayout.xOffset, as: Float.self),
            y: touch.load(fromByteOffset: TouchLayout.yOffset, as: Float.self)
        )
    }
    touchState.track(fingers)
    return 0
}
