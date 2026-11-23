import Foundation
import Network

/// A tiny loopback HTTP server that serves rewritten HLS
/// playlists to AVPlayer as ordinary network resources.
///
/// Why this exists: for the streamxx pattern, the rewritten
/// playlist played INSTANTLY in Safari on the user's phone when
/// it was served over the network (2026-11-14), while the same
/// bytes served through the custom-scheme resource loader never
/// played in five builds and the local-file form did not play
/// either. Every playlist that plays in this app arrives as a
/// network resource, so the player ladder serves the rewritten
/// playlist from 127.0.0.1 and hands AVPlayer a plain http URL —
/// the in-app replica of the proven shape. Only playlists are
/// served (tiny); segments are fetched by AVPlayer directly
/// from their public origin URLs, exactly as in Safari.
///
/// @unchecked Sendable: all mutable state lives on the serial
/// `queue` — the listener, its connections and every handler run
/// there and nowhere else.
final class LocalHLSServer: @unchecked Sendable {
    static let shared = LocalHLSServer()

    private let queue = DispatchQueue(label: "jtv.localhls.server")
    private var listener: NWListener?
    private var bodies: [String: (data: Data, refs: Int)] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var port: UInt16 = 0
    private var startWaiters: [(UInt16?) -> Void] = []

    /// Stores a playlist body and hands back its loopback URL,
    /// starting the listener first if needed. Nil means the server
    /// is unavailable and the caller should use another rung of
    /// its ladder. (Async since the Swift 6 migration — the old
    /// completion form could not cross queue boundaries cleanly.)
    func register(_ data: Data) async -> URL? {
        guard let port = await start() else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async {
                // Content-addressed name (FNV-1a over the
                // bytes): re-registering the same playlist
                // returns the same URL and adds a reference
                // (see deregister), and different playlists
                // never collide in practice.
                var hash: UInt64 = 1469598103934665603
                for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
                let name = "pl-\(hash).m3u8"
                if var entry = self.bodies[name] {
                    entry.refs += 1
                    self.bodies[name] = entry
                } else {
                    self.bodies[name] = (data: data, refs: 1)
                }
                cont.resume(returning: URL(string: "http://127.0.0.1:\(port)/\(name)"))
            }
        }
    }

    /// Releases one registration taken by register(_:): the
    /// body's reference count drops, and at zero the body is
    /// removed, so a loopback URL outlives neither its surface
    /// nor its session attempt. An unknown name is a no-op.
    /// Runs on the server's serial queue through the same
    /// continuation shape as register; callers fire-and-forget
    /// from teardown paths.
    func deregister(_ url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let name = url.lastPathComponent
                if var entry = self.bodies[name] {
                    entry.refs -= 1
                    if entry.refs <= 0 {
                        self.bodies[name] = nil
                    } else {
                        self.bodies[name] = entry
                    }
                }
                cont.resume()
            }
        }
    }

    private func start() async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            queue.async {
                if self.port != 0 { cont.resume(returning: self.port); return }
                self.startWaiters.append { port in cont.resume(returning: port) }
                guard self.listener == nil else { return }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue ?? 0
                        let waiters = self.startWaiters
                        self.startWaiters = []
                        let resolved = self.port != 0 ? self.port : nil
                        waiters.forEach { $0(resolved) }
                    case .failed, .cancelled:
                        self.listener = nil
                        self.port = 0
                        let waiters = self.startWaiters
                        self.startWaiters = []
                        waiters.forEach { $0(nil) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                let waiters = self.startWaiters
                self.startWaiters = []
                waiters.forEach { $0(nil) }
            }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || error != nil {
                self.respond(connection, request: buffer)
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        let text = String(data: request, encoding: .utf8) ?? ""
        let firstLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let path = parts.count >= 2 ? parts[1] : ""
        let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if let entry = bodies[name] {
            let data = entry.data
            // Serve witness (L-25 round 3): this server only
            // ever serves playlists — a handful of reads per
            // play — so a success line is a rare event, not
            // per-segment traffic. The ordered serve lines
            // (master, then media) are the device test's proof
            // AVPlayer walked both tiers over loopback.
            DiagLog.log("hls", "phase=loopback outcome=serve bytes=\(data.count)")
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            DiagLog.log("hls", "phase=loopback outcome=miss")
            let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
