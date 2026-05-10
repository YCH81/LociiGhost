import Foundation
import Testing
@testable import LociiGhostCore

@Suite("DaemonClient round-trip")
struct DaemonClientTests {
    /// Start a tiny in-process Unix-socket echo server that speaks JSON-RPC 2.0
    /// just well enough to round-trip a single `ping` call. We deliberately
    /// avoid pulling in the full daemon -- this is a wire-format test for the
    /// Swift client.
    @Test("ping round-trip")
    func ping() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sockPath = dir.appending(path: "t.sock").path(percentEncoded: false)
        let server = try MiniRPCServer(socketPath: sockPath) { line in
            // Naive: assume JSON object with id and method -- echo back a ping result.
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"]
            else { return nil }
            let resp: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["pong": true, "ok": "yes"],
            ]
            return try JSONSerialization.data(withJSONObject: resp)
        }
        try server.start()
        defer { server.stop() }

        let client = DaemonClient(socketPath: sockPath)
        try await client.connect()
        let raw = try await client.callRaw("ping")
        let data = try JSONEncoder().encode(raw)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"pong\":true"))
        #expect(s.contains("\"ok\":\"yes\""))
        await client.disconnect()
    }

    @Test("connect to nonexistent socket fails cleanly")
    func nonexistentSocket() async throws {
        let client = DaemonClient(socketPath: "/tmp/lociighost-does-not-exist-\(UUID().uuidString).sock")
        do {
            try await client.connect()
            Issue.record("expected connect to fail")
        } catch {
            // expected
        }
    }
}

// MARK: - Tiny test-only server (UNIX socket, JSON-RPC line protocol)

import Darwin

final class MiniRPCServer: @unchecked Sendable {
    typealias Handler = (Data) throws -> Data?

    let socketPath: String
    let handler: Handler
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopped = false

    init(socketPath: String, handler: @escaping Handler) throws {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        unlink(socketPath)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(s >= 0, "socket() failed")

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { cp in
                for (i, b) in bytes.enumerated() { cp[i] = CChar(bitPattern: b) }
                cp[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(s, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(rc == 0, "bind failed errno=\(errno)")
        precondition(listen(s, 1) == 0, "listen failed")

        listenFD = s
        let t = Thread { [self] in self.runLoop() }
        t.name = "MiniRPCServer"
        t.start()
        thread = t
    }

    func stop() {
        stopped = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func runLoop() {
        while !stopped {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    Darwin.accept(listenFD, sp, &len)
                }
            }
            if cfd < 0 { return }
            DispatchQueue.global().async { [self] in self.handleClient(cfd) }
        }
    }

    private func handleClient(_ fd: Int32) {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = tmp.withUnsafeMutableBufferPointer { p in
                Darwin.read(fd, p.baseAddress!, p.count)
            }
            if n <= 0 { close(fd); return }
            buf.append(tmp, count: n)
            while let nlIdx = buf.firstIndex(of: 0x0A) {
                let line = Data(buf[buf.startIndex..<nlIdx])
                buf.removeSubrange(buf.startIndex...nlIdx)
                if var r = try? handler(line) {
                    r.append(0x0A)
                    _ = r.withUnsafeBytes { p in Darwin.write(fd, p.baseAddress!, p.count) }
                }
            }
        }
    }
}
