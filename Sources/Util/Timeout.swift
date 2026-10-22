import Foundation

/// The winner resumes the caller exactly once. Unstructured workers are intentional: a task
/// group waits for losing children, so it cannot enforce a deadline on uncooperative CoreML work.
private final class TimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil {
            lock.unlock()
            tasks.forEach { $0.cancel() }
        } else {
            self.tasks = tasks
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

/// Cancellation and timeout release the caller even if the underlying operation ignores them.
/// Such an operation may still finish in the background; its owner must prevent duplicate work.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    timeoutError: Error? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let work = Task.detached {
                do {
                    try Task.checkCancellation()
                    let value = try await operation()
                    race.finish(.success(value))
                } catch { race.finish(.failure(error)) }
            }
            let timer = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    race.finish(.failure(timeoutError ?? GranulaError.modelLoad(
                        "Загрузка модели заняла больше \(Int(seconds)) с. Попробуйте ещё раз; если ожидание повторяется, перезапустите ZVON."
                    )))
                } catch { /* winner or parent cancellation already resumed the caller */ }
            }
            race.install(tasks: [work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}
