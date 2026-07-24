import Foundation

/// Runs `operation`, but throws if it doesn't finish within `seconds`. Guards against an
/// opaque CoreML/ANE compile hanging forever — the UI gets an error instead of a dead spinner.
/// (A timed-out CoreML compile can't be truly cancelled, but the UI is freed and can retry.)
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GranulaError.modelLoad(
                "Загрузка заняла больше \(Int(seconds)) с — вероятно, зависла компиляция. Попробуйте GPU или модель полегче."
            )
        }
        guard let result = try await group.next() else {
            throw GranulaError.modelLoad("Пустой результат загрузки.")
        }
        group.cancelAll()
        return result
    }
}
