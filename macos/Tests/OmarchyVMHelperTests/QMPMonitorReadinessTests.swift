import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("QMP monitor readiness")
struct QMPMonitorReadinessTests {
    @Test("refused connections retry within a bounded deadline")
    func refusedMonitor() {
        var attempts = 0
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try QMPMonitorReadiness.wait(timeoutMilliseconds: 150, isTargetAlive: { true }) { timeout in
                #expect(timeout > 0 && timeout <= 150)
                attempts += 1
                throw HelperError.io("connection refused")
            }
            Issue.record("An unavailable monitor was declared ready")
        } catch {
            #expect(error.localizedDescription.contains("readiness timed out"))
            #expect(error.localizedDescription.contains("connection refused"))
        }
        #expect(attempts >= 2)
        #expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)
    }

    @Test("QEMU exit during an attempt stops retries immediately")
    func targetExits() {
        var alive = true
        var attempts = 0
        #expect(throws: HelperError.io("QEMU exited before its QMP monitor became ready")) {
            try QMPMonitorReadiness.wait(isTargetAlive: { alive }) { _ in
                attempts += 1
                alive = false
                throw HelperError.io("socket closed")
            }
        }
        #expect(attempts == 1)
    }

    @Test("a silent greeting or capability reply times out and closes the probe", arguments: [false, true])
    func silentMonitor(sendGreeting: Bool) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw HelperError.io("Cannot create readiness test socket")
        }
        defer { close(sockets[1]) }
        if sendGreeting {
            try QMPConnection.writeJSON(["QMP": ["capabilities": []]], to: sockets[1])
        }
        var attempted = false
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try QMPMonitorReadiness.wait(timeoutMilliseconds: 150, isTargetAlive: { true }) { timeout in
                guard !attempted else { throw HelperError.io("monitor still unavailable") }
                attempted = true
                return try QMPConnection(
                    connectedDescriptor: sockets[0],
                    identifierPrefix: "readiness-test",
                    timeoutMilliseconds: timeout
                )
            }
            Issue.record("A silent monitor was declared ready")
        } catch {
            #expect(error.localizedDescription.contains("readiness timed out"))
        }
        #expect(attempted)
        #expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)
        // Drain any capability request and require EOF: failed attempts must
        // release QEMU's single-client monitor for the next connection.
        var bytes = [UInt8](repeating: 0, count: 4096)
        var sawEOF = false
        for _ in 0..<3 {
            var descriptor = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { break }
            if read(sockets[1], &bytes, bytes.count) == 0 {
                sawEOF = true
                break
            }
        }
        #expect(sawEOF)
    }
}
