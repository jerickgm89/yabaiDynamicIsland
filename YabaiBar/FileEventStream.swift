import CoreServices
import Foundation

// Un FSEventStream sobre varias carpetas: el sistema avisa de que algo cambió dentro de ellas, sin que la app mire nada. Los
// avisos llegan juntos, `latency` segundos después del último cambio, y por la cola principal. Sin la bandera de eventos de
// archivo: dice en qué carpeta cambió algo, que es lo que hace falta para saber qué repositorio volver a medir. No pide
// permisos.
@MainActor
final class FileEventStream {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor @Sendable ([String]) -> Void

    /// nil si no hay carpetas o el sistema no puede vigilarlas
    init?(paths: [String], latency: TimeInterval, handler: @escaping @MainActor @Sendable ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let stream = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { stream.handler(paths) }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    /// Hay que llamarlo antes de soltar el objeto: el callback de C lo usa sin retenerlo
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
