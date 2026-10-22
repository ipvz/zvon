import Foundation

// Uses the real timeout implementation, including deliberately non-cooperative operations.
enum TimeoutTests {
    static func delay(_ seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    static func run() async throws {
        var began = Date()
        do {
            _ = try await withTimeout(0.04) { await delay(0.6); return 1 }
            preconditionFailure("expected deadline")
        } catch is CancellationError { preconditionFailure("expected timeout, not cancellation") }
        catch {}
        precondition(Date().timeIntervalSince(began) < 0.4, "deadline waited for uncooperative work")
        print("PASS: timeout returns without waiting for uncooperative work")

        began = Date()
        let task = Task {
            try await withTimeout(10) { await delay(0.6); return 1 }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("expected cancellation") }
        catch is CancellationError {} catch { preconditionFailure("wrong cancellation error") }
        precondition(Date().timeIntervalSince(began) < 0.4)
        print("PASS: parent cancellation returns promptly")

        let result = try await withTimeout(1) { 42 }
        precondition(result == 42)
        for _ in 0..<100 {
            do {
                _ = try await withTimeout(0.001) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                    return 42
                }
            } catch {}
        }
        // Allow losing operations to finish: a double continuation resume would trap here.
        await delay(0.7)
        print("PASS: successful work and 100 deadline races complete exactly once")
    }
}
