import AppKit
import IOKit
import os

// Los dedos sobre el trackpad en cualquier app, para el gesto de 3 o 4 dedos hacia abajo. macOS no tiene API
// pública para gestos de 3 o 4 dedos fuera de las ventanas propias (son del Dock), así que se leen con
// MultitouchSupport, un framework privado de Apple que también usan BetterTouchTool o MiddleClick. No pide
// permisos. Si una versión de macOS lo quita o lo cambia, el gesto deja de funcionar y queda el atajo ⌥I.
@MainActor
final class TrackpadMonitor {
    /// Tras despertar, el trackpad tarda en estar listo: si se registra antes, MultitouchSupport no manda los
    /// toques y el gesto deja de funcionar hasta reiniciar la app (pasó el 2026-11-07, tras días de reposos). Se
    /// vuelve a empezar al segundo y otra vez a los 4 s
    static let restartDelays: [Duration] = [.seconds(1), .seconds(3)]

    private let api = MultitouchAPI()
    /// La lista mantiene vivos los dispositivos mientras se escuchan
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var observers: [NSObjectProtocol] = []
    private var restartTask: Task<Void, Never>?
    /// Avisos de IOKit cuando aparece o desaparece un trackpad (al despertar o al conectar un Magic Trackpad)
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onSwipeDown: @escaping @MainActor @Sendable () -> Void) {
        touchState.setHandler(onSwipeDown)
        start(reason: "al arrancar")
        // Tras el reposo, al encenderse la pantalla o al volver a la sesión, MultitouchSupport puede dejar de
        // mandar los toques: se vuelve a empezar, y de paso se ven los trackpads conectados mientras tanto
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "al despertar"),
            (NSWorkspace.screensDidWakeNotification, "al encenderse la pantalla"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "al volver a la sesión"),
        ]
        observers = events.map { name, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartSoon(reason: reason) }
            }
        }
        deviceChanges.withLock { $0 = { [weak self] in self?.restartSoon(reason: "al cambiar los trackpads") } }
        watchDevices()
    }

    // Se vuelve a empezar varias veces seguidas (ver restartDelays); un aviso nuevo empieza la cuenta otra vez
    private func restartSoon(reason: String) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            for delay in Self.restartDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.stop()
                self?.start(reason: reason)
            }
        }
    }

    private func start(reason: String) {
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
        Logger.app.info("Trackpad: escuchando \(self.devices.count) dispositivos (\(reason, privacy: .public))")
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

    // IOKit avisa cuando aparece o desaparece un AppleMultitouchDevice. El aviso llega en el run loop principal
    private func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("AppleMultitouchDevice"), multitouchDevicesChanged, nil, &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            // Hay que vaciar el iterador para que IOKit empiece a avisar (y los trackpads de ahora no cuentan)
            drain(iterator)
            iterators.append(iterator)
        }
    }
}

// El aviso de IOKit es una función de C, que no captura contexto: lo que hacer va en un estado global
private let deviceChanges = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(initialState: nil)

private func multitouchDevicesChanged(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    drain(iterator)
    guard let handler = deviceChanges.withLock({ $0 }) else { return }
    Task { @MainActor in handler() }
}

private func drain(_ iterator: io_iterator_t) {
    while case let object = IOIteratorNext(iterator), object != 0 {
        IOObjectRelease(object)
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
