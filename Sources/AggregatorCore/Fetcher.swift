import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct FetchResponse {
    let statusCode: Int
    let data: Data
    let etag: String?
    let lastModified: String?

    var isNotModified: Bool { statusCode == 304 }
}

enum FetchError: Error, Equatable {
    case httpStatus(Int)
    case notHTTP
    /// Finding 3e: the response body exceeded the caller's size cap -- the transfer was
    /// refused up front (declared Content-Length over the cap) or aborted mid-flight.
    case responseTooLarge(limit: Int)
}

/// Finding 3e: response-size caps. A runaway or hostile response must never buffer without
/// bound on the CI runner. Both caps sit far above anything a legitimate source serves.
enum FetchLimits {
    /// Feeds and article pages.
    static let pageBytes = 10 * 1024 * 1024
    /// Hero images (pre-resize originals).
    static let imageBytes = 30 * 1024 * 1024
}

/// The cap decisions, kept pure so they're unit-testable without a live server.
enum SizeCap {
    /// True when the server DECLARES a body bigger than the limit (Content-Length known up
    /// front) -- abort before downloading anything. Unknown length (-1) or an empty body (0)
    /// never aborts here; the streaming check below covers an undeclared oversize body.
    static func declaredLengthExceeds(limit: Int?, declared: Int64) -> Bool {
        guard let limit, declared > 0 else { return false }
        return declared > Int64(limit)
    }

    /// True when the accumulated body has grown past the limit -- abort mid-stream.
    static func accumulatedExceeds(limit: Int?, count: Int) -> Bool {
        guard let limit else { return false }
        return count > limit
    }
}

/// The compiler's HTTP seam. Production is `Fetcher`; tests use fakes.
protocol AggregatorHTTPClient {
    /// GET with optional conditional headers (If-None-Match / If-Modified-Since) and an
    /// optional response-size cap (finding 3e; nil = uncapped). Returns 304 as a normal
    /// `FetchResponse` (`isNotModified`); throws `FetchError.httpStatus` for any other
    /// non-2xx and `FetchError.responseTooLarge` for a body over the cap.
    func get(_ url: URL, conditional: FeedConditional?, maxBytes: Int?) async throws -> FetchResponse
}

extension AggregatorHTTPClient {
    func get(_ url: URL) async throws -> FetchResponse {
        try await get(url, conditional: nil, maxBytes: nil)
    }

    func get(_ url: URL, maxBytes: Int?) async throws -> FetchResponse {
        try await get(url, conditional: nil, maxBytes: maxBytes)
    }

    func get(_ url: URL, conditional: FeedConditional?) async throws -> FetchResponse {
        try await get(url, conditional: conditional, maxBytes: nil)
    }
}

final class Fetcher: AggregatorHTTPClient {
    /// Honest fetcher identification (politeness requirement) -- unlike the app (a personal
    /// on-device reader that presents as Safari), this is an automated compiler and says so.
    static let userAgent = "BroadsheetEditionCompiler/1.0 (+https://github.com/dankelleghan-ops; single-user personal news reader; contact via GitHub)"

    /// Mirrors the app's `NetworkClient` timeouts (20s).
    static let timeoutSeconds: TimeInterval = 20

    private let session: URLSession
    private let capDelegate: SizeCapSessionDelegate

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = 60
        // We manage conditionals ourselves via the state file -- an opaque URLCache would
        // hide the 304s the run report wants to count.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        capDelegate = SizeCapSessionDelegate()
        session = URLSession(configuration: configuration, delegate: capDelegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func get(_ url: URL, conditional: FeedConditional?, maxBytes: Int?) async throws -> FetchResponse {
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutSeconds)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = conditional?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = conditional?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (http, data) = try await capDelegate.perform(request, on: session, maxBytes: maxBytes)
        if http.statusCode == 304 {
            return FetchResponse(statusCode: 304, data: Data(),
                                 etag: conditional?.etag, lastModified: conditional?.lastModified)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
        }
        return FetchResponse(
            statusCode: http.statusCode,
            data: data,
            etag: headerValue("Etag", in: http),
            lastModified: headerValue("Last-Modified", in: http)
        )
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        // value(forHTTPHeaderField:) is case-insensitive on Darwin; corelibs-foundation has
        // historically been stricter, so probe common casings explicitly.
        for candidate in [name, name.lowercased(), name.uppercased()] {
            if let value = response.value(forHTTPHeaderField: candidate) { return value }
        }
        return nil
    }
}

/// URLSessionDataDelegate that enforces a per-task byte cap while streaming (finding 3e):
/// refuses a declared-oversize Content-Length before the body arrives, and cancels the task
/// the moment the accumulated body crosses the cap -- an oversize download is aborted
/// mid-flight, never buffered to completion. Delegate-based rather than
/// `URLSession.bytes(for:)` because the compiler's production platform is Linux
/// (corelibs-foundation), where the delegate API is the portable streaming surface.
final class SizeCapSessionDelegate: NSObject, URLSessionDataDelegate {
    private struct InFlight {
        var maxBytes: Int?
        var data = Data()
        var response: HTTPURLResponse?
        var notHTTP = false
        var tooLarge = false
        var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
    }

    private let lock = NSLock()
    private var inFlight: [Int: InFlight] = [:]

    func perform(_ request: URLRequest, on session: URLSession,
                 maxBytes: Int?) async throws -> (HTTPURLResponse, Data) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            inFlight[task.taskIdentifier] = InFlight(maxBytes: maxBytes, continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var flight = inFlight[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            flight.response = http
        } else {
            flight.notHTTP = true
        }
        if SizeCap.declaredLengthExceeds(limit: flight.maxBytes, declared: response.expectedContentLength) {
            flight.tooLarge = true
        }
        let abort = flight.tooLarge || flight.notHTTP
        inFlight[dataTask.taskIdentifier] = flight
        lock.unlock()
        completionHandler(abort ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var flight = inFlight[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        flight.data.append(data)
        let crossedCap = SizeCap.accumulatedExceeds(limit: flight.maxBytes, count: flight.data.count)
        if crossedCap { flight.tooLarge = true }
        inFlight[dataTask.taskIdentifier] = flight
        lock.unlock()
        if crossedCap { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let flight = inFlight.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        // The over-cap flag wins over the cancellation error our own task.cancel() produced.
        if flight.tooLarge {
            flight.continuation.resume(throwing: FetchError.responseTooLarge(limit: flight.maxBytes ?? 0))
        } else if flight.notHTTP {
            flight.continuation.resume(throwing: FetchError.notHTTP)
        } else if let error {
            flight.continuation.resume(throwing: error)
        } else if let response = flight.response {
            flight.continuation.resume(returning: (response, flight.data))
        } else {
            flight.continuation.resume(throwing: FetchError.notHTTP)
        }
    }
}
