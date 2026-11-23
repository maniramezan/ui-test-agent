import Foundation
import Testing

@testable import MoqBridge

/// Answers requests from a script keyed by "METHOD path" and records what was sent.
actor StubTransport: HTTPTransport {
    enum Reply {
        case status(Int, body: String = "")
        case failure
    }

    struct Sent: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private var replies: [String: [Reply]]
    private(set) var sent: [Sent] = []

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = try #require(request.url)
        let key = "\(method) \(url.path())"
        sent.append(Sent(method: method, path: url.path(), headers: request.allHTTPHeaderFields ?? [:]))
        var queue = replies[key] ?? []
        guard !queue.isEmpty else {
            throw URLError(.cannotConnectToHost)
        }
        let reply = queue.count > 1 ? queue.removeFirst() : queue[0]
        replies[key] = queue
        switch reply {
        case .failure:
            throw URLError(.cannotConnectToHost)
        case .status(let code, let body):
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }
}

enum Fixtures {
    static func config(
        adminAuth: AdminAuth = .none,
        readinessTimeoutSeconds: Double = 1,
        launchEnvironment: [String: String] = [
            "APP_BASE_URL": "{{baseURL}}",
            "APP_SESSION": "{{sessionId}}",
            "APP_FIXED": "127.0.0.1:9099",
        ]
    ) -> AppConfig {
        AppConfig(
            app: "sample",
            server: .init(
                port: 8080,
                adminHost: "127.0.0.1",
                readinessPath: "/_admin/endpoints",
                readinessTimeoutSeconds: readinessTimeoutSeconds,
                adminAuth: adminAuth
            ),
            platforms: [
                "ios": .init(
                    appHost: "127.0.0.1", requireSession: true, launchEnvironment: launchEnvironment),
                "android": .init(
                    appHost: "10.0.2.2", requireSession: false, launchEnvironment: launchEnvironment),
            ]
        )
    }
}
