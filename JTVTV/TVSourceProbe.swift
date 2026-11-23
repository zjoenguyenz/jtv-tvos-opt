import Foundation

/// JTV tvOS 1.3.3 (L-T23) — time-to-first-byte probe for an
/// ALREADY-RESOLVED stream URL, used by the player session's
/// measured source selection for multi-source titles.
///
/// This helper only TIMES a URL the protected resolve
/// machinery (MovieService / PluginEngine) produced. It is
/// not a fetch path: nothing it downloads is kept or played,
/// the transfer is cancelled the moment the first bytes land,
/// and it never touches the shared `Net` machinery in
/// Cache.swift — the app's real fetching is unchanged.
enum TVSourceProbe {

    /// Milliseconds until the first response body byte, or
    /// nil when the URL produced nothing within `timeout`
    /// (refused, stalled, errored). A Range request asks for a
    /// single byte; servers that ignore Range simply start
    /// streaming and are cancelled after the first chunk, so
    /// the measurement is the same either way.
    static func timeToFirstByte(url: URL, headers: [String: String],
                                timeout: TimeInterval = 3) async -> Int? {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "Range") == nil {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }
        let delegate = FirstByteDelegate()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration,
                                 delegate: delegate, delegateQueue: queue)
        let result: Int? = await withCheckedContinuation { continuation in
            delegate.arm(continuation: continuation)
            let task = session.dataTask(with: request)
            delegate.attach(task: task, queue: queue)
            task.resume()
            // The budget enforcer: whichever of first-byte,
            // completion, or this deadline lands first wins;
            // the delegate resumes exactly once.
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                delegate.expire()
            }
        }
        session.invalidateAndCancel()
        return result
    }

    /// Resume-once delegate. All mutable state is touched
    /// only on the session's serial delegate queue or before
    /// the task resumes (arm/attach — a happens-before edge:
    /// nothing runs until `task.resume()`), except `expire()`,
    /// which hops onto that same queue — so the
    /// resume-exactly-once invariant needs no lock. The
    /// `@unchecked Sendable` conformance states exactly that
    /// confinement for the compiler: the budget-enforcer Task
    /// captures the delegate (gate Round 1, Lens A A1) and is
    /// sound precisely because `expire()` only enqueues onto
    /// the serial queue and never touches state itself.
    private final class FirstByteDelegate: NSObject, URLSessionDataDelegate,
        @unchecked Sendable {
        private var continuation: CheckedContinuation<Int?, Never>?
        private var task: URLSessionDataTask?
        private var started: Date?
        private var finished = false
        /// The serial queue the owning URLSession delivers
        /// callbacks on; expire() re-enters through it.
        private var callbackQueue: OperationQueue?

        func arm(continuation: CheckedContinuation<Int?, Never>) {
            self.continuation = continuation
            self.started = Date()
        }

        func attach(task: URLSessionDataTask, queue: OperationQueue) {
            self.task = task
            // The queue is the session's own delegate queue,
            // handed in by the caller that created both: a
            // URLSessionTask exposes no `session` back-pointer
            // in the tvOS SDK (CI run #19 convicted the assumed
            // API), so the queue travels explicitly.
            self.callbackQueue = queue
        }

        func expire() {
            // attach() always precedes the deadline task, so
            // the queue exists; if it somehow does not, the
            // session's own request timeout still completes
            // the task and lands in didCompleteWithError.
            guard let queue = callbackQueue else { return }
            queue.addOperation { [weak self] in
                self?.finish(nil)
            }
        }

        private func finish(_ value: Int?) {
            guard !finished else { return }
            finished = true
            task?.cancel()
            continuation?.resume(returning: value)
            continuation = nil
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            guard let started else { finish(nil); return }
            finish(Int(Date().timeIntervalSince(started) * 1000))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            // Completion with no body byte (or an error before
            // any data) is a failed probe.
            finish(nil)
        }
    }
}
