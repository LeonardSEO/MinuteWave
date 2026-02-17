import Foundation

enum HTTPRetryPolicy {
    struct Configuration {
        var maxAttempts: Int
        var baseDelaySeconds: Double
        var maxDelaySeconds: Double
    }

    static let azureDefault = Configuration(
        maxAttempts: 5,
        baseDelaySeconds: 0.5,
        maxDelaySeconds: 8
    )

    static func send(
        request: URLRequest,
        session: URLSession = .shared,
        configuration: Configuration = HTTPRetryPolicy.azureDefault
    ) async throws -> (Data, HTTPURLResponse) {
        try await execute(configuration: configuration) {
            try await session.data(for: request)
        }
    }

    static func execute(
        configuration: Configuration = HTTPRetryPolicy.azureDefault,
        operation: @escaping @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        let maxAttempts = max(1, configuration.maxAttempts)
        var lastTransportError: Error?

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await operation()
                guard let http = response as? HTTPURLResponse else {
                    throw AppError.networkFailure(reason: "No HTTP response received.")
                }

                if shouldRetry(statusCode: http.statusCode), attempt < maxAttempts {
                    try await sleepBeforeRetry(
                        attempt: attempt,
                        retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                        configuration: configuration
                    )
                    continue
                }

                return (data, http)
            } catch {
                if shouldRetry(error: error), attempt < maxAttempts {
                    lastTransportError = error
                    try await sleepBeforeRetry(
                        attempt: attempt,
                        retryAfterHeader: nil,
                        configuration: configuration
                    )
                    continue
                }
                throw error
            }
        }

        if let lastTransportError {
            throw lastTransportError
        }
        throw AppError.networkFailure(reason: "Request failed after retry attempts.")
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func shouldRetry(error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            return false
        }

        return ns.code == NSURLErrorTimedOut
            || ns.code == NSURLErrorNetworkConnectionLost
            || ns.code == NSURLErrorNotConnectedToInternet
            || ns.code == NSURLErrorCannotConnectToHost
            || ns.code == NSURLErrorCannotFindHost
            || ns.code == NSURLErrorDNSLookupFailed
    }

    private static func sleepBeforeRetry(
        attempt: Int,
        retryAfterHeader: String?,
        configuration: Configuration
    ) async throws {
        if let retryAfterSeconds = parseRetryAfterSeconds(retryAfterHeader), retryAfterSeconds > 0 {
            try await Task.sleep(for: .milliseconds(Int(retryAfterSeconds * 1_000)))
            return
        }

        let baseDelay = min(
            configuration.maxDelaySeconds,
            configuration.baseDelaySeconds * pow(2, Double(max(0, attempt - 1)))
        )
        let jittered = min(configuration.maxDelaySeconds, baseDelay * Double.random(in: 0.75...1.25))
        try await Task.sleep(for: .milliseconds(Int(jittered * 1_000)))
    }

    private static func parseRetryAfterSeconds(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: trimmed) else { return nil }

        let delay = date.timeIntervalSinceNow
        return delay > 0 ? delay : 0
    }
}
