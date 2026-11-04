import AudioToolbox
import CoreAudio
import os

// Lógica pura del fundido de volumen
enum VolumeFade {
    /// Los pasos de un fundido de `from` a `to`, con curva suave (smoothstep): empieza y acaba despacio
    static func steps(from: Float, to: Float, count: Int) -> [Float] {
        guard count > 0 else { return [to] }
        return (1...count).map { step in
            // El último paso es justo el destino, sin errores de redondeo
            guard step < count else { return to }
            let t = Float(step) / Float(count)
            return from + (to - from) * t * t * (3 - 2 * t)
        }
    }

    /// Si el volumen sigue como lo dejó el fundido: si no, lo has tocado tú y no se te quita
    static func isUntouched(current: Float, lastSet: Float) -> Bool {
        abs(current - lastSet) < 0.02
    }
}

// Baja y sube con suavidad el volumen de la salida por defecto, con CoreAudio y sin permisos. Recuerda el que había
// y no lo devuelve si lo tocas tú mientras está bajado. Si la app se cierra con el volumen bajado, lo guarda en
// UserDefaults y lo devuelve al volver a abrirse, si sigue igual.
@MainActor
final class VolumeDucker {
    private struct Duck: Codable {
        var deviceUID: String
        var original: Float
        var lastSet: Float
    }

    private static let key = "duckedVolume"
    private static let fadeSteps = 24

    private let defaults: UserDefaults
    private var duck: Duck? {
        didSet {
            if let duck { defaults.set(try? JSONEncoder().encode(duck), forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        }
    }
    private var fadeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?

    var isDucked: Bool { duck != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreLeftover()
    }

    /// Baja el volumen a `fraction` del que había. Sin salida que lo permita, o en silencio, no hace nada
    func duck(to fraction: Double, over duration: Duration) {
        guard duck == nil, let device = Self.defaultOutput(), let uid = Self.uid(of: device),
              !Self.isMuted(device), let current = Self.volume(of: device) else { return }
        let target = current * Float(fraction)
        duck = Duck(deviceUID: uid, original: current, lastSet: current)
        Logger.app.info("Volumen: baja del \(Int(current * 100)) % al \(Int(target * 100)) %")
        fadeTask = fade(device: device, from: current, to: target, over: duration)
    }

    /// Devuelve el volumen que había, salvo que lo hayas tocado. Si ya se está devolviendo, espera a que acabe
    func restore(over duration: Duration) async {
        if let restoreTask { return await restoreTask.value }
        guard let duck, let device = Self.device(uid: duck.deviceUID) else {
            self.duck = nil
            return
        }
        fadeTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if let current = Self.volume(of: device), VolumeFade.isUntouched(current: current, lastSet: duck.lastSet) {
                Logger.app.info("Volumen: vuelve al \(Int(duck.original * 100)) %")
                await fade(device: device, from: current, to: duck.original, over: duration).value
            } else {
                Logger.app.info("Volumen: lo tocaste tú, se queda como está")
            }
            self.duck = nil
            restoreTask = nil
        }
        restoreTask = task
        await task.value
    }

    /// Al salir de la app: lo devuelve de golpe, sin esperar
    func restoreNow() {
        fadeTask?.cancel()
        guard let duck, let device = Self.device(uid: duck.deviceUID) else { return }
        if let current = Self.volume(of: device), VolumeFade.isUntouched(current: current, lastSet: duck.lastSet) {
            Self.setVolume(duck.original, of: device)
        }
        self.duck = nil
    }

    // Si la app se cerró con el volumen bajado y nadie lo ha tocado, lo devuelve
    private func restoreLeftover() {
        guard let data = defaults.data(forKey: Self.key), let leftover = try? JSONDecoder().decode(Duck.self, from: data) else { return }
        duck = leftover
        restoreNow()
    }

    // Cada paso comprueba que no hayas tocado el volumen; si lo tocas, el fundido se para y no se te quita
    @discardableResult
    private func fade(device: AudioObjectID, from: Float, to: Float, over duration: Duration) -> Task<Void, Never> {
        let steps = VolumeFade.steps(from: from, to: to, count: Self.fadeSteps)
        let interval = duration / Self.fadeSteps
        return Task { [weak self] in
            for step in steps {
                try? await Task.sleep(for: interval, tolerance: .milliseconds(10))
                guard let self, !Task.isCancelled, var duck = self.duck else { return }
                guard let current = Self.volume(of: device), VolumeFade.isUntouched(current: current, lastSet: duck.lastSet) else {
                    Logger.app.info("Volumen: lo tocaste tú durante el fundido")
                    self.duck = nil
                    return
                }
                Self.setVolume(step, of: device)
                duck.lastSet = step
                self.duck = duck
            }
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device
            )
        }
        return status == noErr && device != 0 ? device : nil
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    /// nil si la salida no deja cambiar su volumen (algunos DAC o HDMI)
    private static func volume(of device: AudioObjectID) -> Float? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    private static func setVolume(_ volume: Float, of device: AudioObjectID) {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = Float32(max(0, min(1, volume)))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
