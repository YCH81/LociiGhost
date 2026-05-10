import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// JSON-RPC 2.0 client over a Unix domain socket.
///
/// Design notes:
///
/// 1. State (pending continuations, fd, ID counter) lives on the actor.
/// 2. The blocking `read(2)` call lives on a background thread, **off the
///    actor's executor**. If we did the blocking read inside the actor we'd
///    deadlock the actor: a read syscall holding the actor's executor
///    prevents `callRaw` from ever entering to register its continuation.
/// 3. The reader thread parses bytes into newline-delimited JSON frames and
///    hands each frame back to the actor as an async task for dispatch.
///
/// Idle-friendly: no heartbeat, no polling. The reader thread blocks in
/// `read()` (kernel sleeps the thread, 0% CPU). The actor is only woken
/// when a frame arrives or a caller invokes `callRaw`.
public actor DaemonClient {
    public enum ConnectionError: Error, CustomStringConvertible {
        case socketCreateFailed(errno: Int32)
        case connectFailed(errno: Int32, path: String)
        case alreadyConnected
        case notConnected
        case responseDecodingFailed(String)
        case unexpectedResponse(String)
        case writeFailed(errno: Int32)

        public var description: String {
            switch self {
            case .socketCreateFailed(let e):
                return "socket() failed (errno=\(e))"
            case .connectFailed(let e, let p):
                return "connect(\(p)) failed (errno=\(e))"
            case .alreadyConnected:
                return "DaemonClient already connected"
            case .notConnected:
                return "DaemonClient is not connected"
            case .responseDecodingFailed(let s):
                return "Failed to decode response: \(s)"
            case .unexpectedResponse(let s):
                return "Unexpected response shape: \(s)"
            case .writeFailed(let e):
                return "write() failed (errno=\(e))"
            }
        }
    }

    private let socketPath: String
    private var fd: Int32 = -1
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<AnyCodable, Error>] = [:]
    private var reader: ReaderThread?

    /// Server-pushed notifications. Method begins with `event.`.
    public nonisolated let events: AsyncStream<RPCEvent>
    private nonisolated let _eventCont: AsyncStream<RPCEvent>.Continuation

    public init(socketPath: String) {
        self.socketPath = socketPath
        var cont: AsyncStream<RPCEvent>.Continuation!
        self.events = AsyncStream<RPCEvent> { c in cont = c }
        self._eventCont = cont
    }

    public func connect() async throws {
        if fd >= 0 { throw ConnectionError.alreadyConnected }

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ConnectionError.socketCreateFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s)
            throw ConnectionError.connectFailed(errno: ENAMETOOLONG, path: socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { cptr in
                for (i, b) in pathBytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[pathBytes.count] = 0
            }
        }

        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(s, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(s)
            throw ConnectionError.connectFailed(errno: e, path: socketPath)
        }

        fd = s

        // Spawn the reader thread. It captures `s` (the fd) by value; closing
        // `s` from disconnect() causes the read syscall to fail with EBADF
        // and the thread exits cleanly.
        let r = ReaderThread(fd: s) { [weak self] line in
            guard let self else { return }
            Task { await self.dispatchIncoming(line) }
        }
        r.start()
        reader = r
    }

    public func disconnect() async {
        guard fd >= 0 else { return }

        // Closing the fd unblocks the reader thread (read returns -1/EBADF).
        let oldFD = fd
        fd = -1
        close(oldFD)
        reader = nil

        // Fail every in-flight call with notConnected.
        let inFlight = pending
        pending.removeAll()
        for (_, cont) in inFlight {
            cont.resume(throwing: ConnectionError.notConnected)
        }
    }

    /// Issue a JSON-RPC call and decode the result into a typed value.
    public func call<R: Decodable & Sendable>(
        _ method: String,
        params: [String: AnyCodable] = [:],
        as: R.Type = R.self
    ) async throws -> R {
        let raw = try await callRaw(method, params: params)
        let data = try JSONEncoder().encode(raw)
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw ConnectionError.responseDecodingFailed(String(describing: error))
        }
    }

    /// Issue a call, returning the type-erased JSON result.
    public func callRaw(_ method: String, params: [String: AnyCodable] = [:]) async throws -> AnyCodable {
        guard fd >= 0 else { throw ConnectionError.notConnected }
        let id = nextID
        nextID += 1

        var payload: [String: AnyCodable] = [
            "jsonrpc": AnyCodable(JSONRPC.version),
            "id": AnyCodable(id),
            "method": AnyCodable(method),
        ]
        if !params.isEmpty {
            payload["params"] = AnyCodable(params)
        }

        let line = try JSONEncoder().encode(payload) + Data([0x0A])

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AnyCodable, Error>) in
            pending[id] = cont
            do {
                try writeAll(line)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    public func notify(_ method: String, params: [String: AnyCodable] = [:]) async throws {
        guard fd >= 0 else { throw ConnectionError.notConnected }
        var payload: [String: AnyCodable] = [
            "jsonrpc": AnyCodable(JSONRPC.version),
            "method": AnyCodable(method),
        ]
        if !params.isEmpty { payload["params"] = AnyCodable(params) }
        let line = try JSONEncoder().encode(payload) + Data([0x0A])
        try writeAll(line)
    }

    // MARK: - Internal

    private func writeAll(_ data: Data) throws {
        var written = 0
        let total = data.count
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let base = buf.baseAddress!
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ConnectionError.writeFailed(errno: errno)
                }
                written += n
            }
        }
    }

    fileprivate func dispatchIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let idAny = obj["id"], let id = idAny as? Int, let cont = pending.removeValue(forKey: id) {
            if let errObj = obj["error"] as? [String: Any] {
                let code = (errObj["code"] as? Int) ?? -32603
                let msg = (errObj["message"] as? String) ?? "rpc error"
                cont.resume(throwing: RPCError(code: code, message: msg))
            } else {
                let resultObj = obj["result"] ?? NSNull()
                let resultData = (try? JSONSerialization.data(withJSONObject: resultObj)) ?? Data("null".utf8)
                if let decoded = try? JSONDecoder().decode(AnyCodable.self, from: resultData) {
                    cont.resume(returning: decoded)
                } else {
                    cont.resume(throwing: ConnectionError.responseDecodingFailed("result"))
                }
            }
            return
        }

        // Notification (no id) -- forward to the events stream.
        if let method = obj["method"] as? String {
            let params = obj["params"] as? [String: Any] ?? [:]
            let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            let decoded = (try? JSONDecoder().decode([String: AnyCodable].self, from: paramsData)) ?? [:]
            _eventCont.yield(RPCEvent(method: method, params: decoded))
        }
    }
}

public struct RPCEvent: Sendable {
    public let method: String
    public let params: [String: AnyCodable]
}

// MARK: - Reader thread

/// Blocking-read background thread. Lives off the actor's executor so it
/// can sleep in the kernel without holding actor isolation. Each newline-
/// delimited frame is delivered to the supplied callback.
private final class ReaderThread: @unchecked Sendable {
    private let fd: Int32
    private let onFrame: @Sendable (Data) -> Void
    private var thread: Thread?

    init(fd: Int32, onFrame: @escaping @Sendable (Data) -> Void) {
        self.fd = fd
        self.onFrame = onFrame
    }

    func start() {
        let t = Thread { [fd, onFrame] in
            ReaderThread.runLoop(fd: fd, onFrame: onFrame)
        }
        t.name = "LociiGhost.DaemonClient.reader"
        t.start()
        thread = t
    }

    private static func runLoop(fd: Int32, onFrame: @Sendable (Data) -> Void) {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = tmp.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress!, ptr.count)
            }
            if n <= 0 { return }                    // 0 = EOF, -1 = closed/error
            buffer.append(tmp, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if !frame.isEmpty {
                    onFrame(frame)
                }
            }
        }
    }
}
