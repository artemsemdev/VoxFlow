import Dispatch

enum MemoryPressureEvents {
    static func system() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let queue = DispatchQueue(label: "dev.artemsem.voxflow.style-memory-pressure", qos: .utility)
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical], queue: queue
            )
            source.setEventHandler { continuation.yield(()) }
            continuation.onTermination = { _ in source.cancel() }
            source.activate()
        }
    }
}
