import AppKit
import SwiftUI
import Darwin

@main struct CodexUsageTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "CodexUsageTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func decode(_ json: String) throws -> CodexUsageResponse { try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8)) }
    static let fixture = #"{"rateLimits":{"limitId":"codex","planType":"pro","primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null}}"#
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let bucket = try decode(fixture).codex!
        try expect(bucket.remainingPercent == 37 && bucket.windows.count == 1 && bucket.windows[0].period == "Неделя", "Use actual periods; a weekly primary must not be mislabeled as five hours")
        let multi = try decode(#"{"rateLimits":{"primary":{"usedPercent":5}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":94,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":100}}}}"#)
        try expect(multi.codex?.remainingPercent == 6, "Select the Codex bucket and the most restrictive window")
        try expect(tryDecodeRemaining(#"{"rateLimits":{"primary":{"usedPercent":-5},"secondary":{"usedPercent":130}}}"#) == 0, "Clamp percentages to 0…100")
        try expect(tryDecodeBucket(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":3}}}"#) == nil, "Never substitute a model-specific bucket")
        let snapshot = CodexUsageSnapshot(bucket: bucket, fetchedAt: Date(timeIntervalSince1970: 1999999900))
        try expect(!snapshot.isStale(at: snapshot.fetchedAt) && snapshot.isStale(at: Date(timeIntervalSince1970: 2000000000)), "A passed reset must invalidate the snapshot, never synthesize 100%")
        let expired = CodexUsageSnapshot(bucket: bucket, fetchedAt: Date(timeIntervalSince1970: 2000000001))
        try expect(expired.isStale(at: expired.fetchedAt), "An already expired backend snapshot must remain stale")
        let timeless = try decode(#"{"rateLimits":{"primary":{"usedPercent":25}}}"#).codex!
        try expect(CodexUsageSnapshot(bucket: timeless, fetchedAt: .distantPast).isStale(at: Date()), "Old snapshots must not look current")
        try await transport()
        try await storeAndPreview(bucket)
        if ProcessInfo.processInfo.environment["CODEX_USAGE_LIVE"] == "1" {
            let actual = try await CodexUsageClient().read()
            print("PASS: live Codex read, remaining \(actual.bucket.remainingPercent.map(String.init) ?? "unavailable")%, \(actual.bucket.windows.count) period(s)")
        }
        print("PASS: Codex bucket selection, percentages, periods, stale/reset handling, IPC, cancellation, coalescing and menu preview")
    }
    static func tryDecodeBucket(_ value: String) -> CodexUsageBucket? { try? decode(value).codex }
    static func tryDecodeRemaining(_ value: String) -> Int? { try? decode(value).codex?.remainingPercent }

    static func transport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zvon-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func executable(_ name: String, _ body: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys,json,time,os,signal\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let good = try executable("good", """
        expected=['initialize','initialized','account/read','account/rateLimits/read']
        for method in expected:
            request=json.loads(sys.stdin.readline())
            assert request['method']==method, 'Read-only protocol required'
            if method=='initialized': continue
            result = {} if method=='initialize' else ({'account':{'type':'chatgpt'}} if method=='account/read' else json.loads('\(fixture)'))
            line=json.dumps({'id':request['id'],'result':result})+'\\n'
            # Partial lines must be reassembled; unrelated notifications must be ignored.
            sys.stdout.write('{"method":"account/updated","params":{}}\\n');sys.stdout.flush()
            sys.stdout.write(line[:8]);sys.stdout.flush();time.sleep(.01)
            sys.stdout.write(line[8:]);sys.stdout.flush()
        sys.stdin.read()
        """)
        let result = try await CodexUsageClient(executable: good, timeout: 3).read()
        try expect(result.bucket.remainingPercent == 37, "Real pipe transport must handle fragmented JSON without losing messages")
        let signedOut = try executable("signed-out", """
        for line in sys.stdin:
            r=json.loads(line)
            if 'id' not in r: continue
            print(json.dumps({'id':r['id'],'result':{'account':None}}),flush=True)
        """)
        do { _ = try await CodexUsageClient(executable: signedOut, timeout: 3).read(); throw TestFailure() }
        catch CodexUsageError.signedOut {}
        let bad = try executable("bad", "print('not json',flush=True)\ntime.sleep(5)\n")
        do { _ = try await CodexUsageClient(executable: bad, timeout: 3).read(); throw TestFailure() }
        catch CodexUsageError.invalidResponse {}
        let earlyExit = try executable("exit", "sys.exit(0)\n")
        do { _ = try await CodexUsageClient(executable: earlyExit, timeout: 3).read(); throw TestFailure() }
        catch is TestFailure { throw TestFailure() } catch {}
        let pidFile = dir.appendingPathComponent("pid")
        let hang = try executable("hang", """
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        open('\(pidFile.path)','w').write(str(os.getpid()))
        time.sleep(60)
        """)
        let started = Date()
        do { _ = try await CodexUsageClient(executable: hang, timeout: 0.25).read(); throw TestFailure() }
        catch CodexUsageError.timeout {}
        try expect(Date().timeIntervalSince(started) < 3, "Timeout including process cleanup must be bounded")
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try expect(kill(pid, 0) == -1 && errno == ESRCH, "A hung CLI must be reaped, not left in the background")
        let task = Task { try await CodexUsageClient(executable: hang, timeout: 30).read() }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; throw TestFailure() } catch is CancellationError {}
        let cancelledPID = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try expect(kill(cancelledPID, 0) == -1, "Cancellation must terminate its child")
        print("PASS: read-only RPC, fragmented responses, signed-out, malformed data, child exit, timeout and cancellation cleanup")
    }

    @MainActor static func storeAndPreview(_ bucket: CodexUsageBucket) async throws {
        let name = "ZVONCodexTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let client = FakeReader(snapshot: CodexUsageSnapshot(bucket: bucket, fetchedAt: Date()))
        var now = Date()
        let store = CodexUsageStore(client: client, defaults: defaults, now: { now })
        store.refresh(); store.refresh(); store.refresh()
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        let calls = await client.calls
        try expect(calls == 1 && store.remaining() == 37, "Concurrent refreshes must coalesce")
        store.refresh(); try await Task.sleep(for: .milliseconds(20))
        let throttled = await client.calls
        try expect(throttled == 1, "Opening the popover repeatedly must not spawn processes")
        let view = NSHostingView(rootView: CodexUsagePopover(store: store).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        view.layoutSubtreeIfNeeded()
        try FileManager.default.createDirectory(atPath: ".build/codex-tests", withIntermediateDirectories: true)
        for (appearance, filename) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            view.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(60))
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/codex-tests/\(filename).png"))
            let base = NSImage(size: CGSize(width: 55, height: 22))
            let badge = CodexUsageGlyph.append(to: base, remaining: 37, dark: appearance == .darkAqua)
            try expect(badge.boundary > base.size.width && badge.image.size.width < 135, "Badge should remain compact and preserve previous click targets")
            let data = NSBitmapImageRep(data: badge.image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try data.write(to: URL(fileURLWithPath: ".build/codex-tests/badge-\(filename).png"))
        }
        panel.contentView = nil; panel.close()
        await client.setFailure(.unavailable)
        now = now.addingTimeInterval(31); store.refresh()
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(store.snapshot != nil && store.remaining() == nil && store.error == .unavailable, "Network failure must label cached data and hide the live percentage")
        await client.setFailure(.signedOut)
        now = now.addingTimeInterval(31); store.refresh()
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(store.snapshot == nil && store.error == .signedOut, "Sign-out must remove the previous account's allowance")
        await client.setFailure(nil)
        store.enabled = false
        try expect(store.snapshot == nil && !store.isRefreshing && store.remaining() == nil, "Disabling must clear data and stop work")
        store.enabled = true
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(store.remaining() == 37, "Re-enabling should refresh immediately")
        let beforeSleep = await client.calls
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30)); store.refresh()
        let duringSleep = await client.calls
        try expect(duringSleep == beforeSleep && !store.isRefreshing, "Sleep must suspend polling")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let afterWake = await client.calls
        try expect(afterWake == beforeSleep + 1 && store.remaining() == 37, "Wake must perform one immediate refresh")
        now = now.addingTimeInterval(31); store.refresh(); store.enabled = false
        try await Task.sleep(for: .milliseconds(80))
        try expect(store.snapshot == nil && !store.isRefreshing, "A late cancelled response must not restore disabled usage data")
        store.stop()
    }
    struct TestFailure: Error {}
}

private actor FakeReader: CodexUsageReading {
    let snapshot: CodexUsageSnapshot
    var calls = 0
    var failure: CodexUsageError?
    func setFailure(_ value: CodexUsageError?) { failure = value }
    init(snapshot: CodexUsageSnapshot) { self.snapshot = snapshot }
    func read() async throws -> CodexUsageSnapshot {
        calls += 1; try await Task.sleep(for: .milliseconds(30))
        if let failure { throw failure }
        return snapshot
    }
}
