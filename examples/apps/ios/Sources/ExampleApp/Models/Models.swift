import Foundation

struct User: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var email: String
}

struct SessionPayload: Codable, Sendable, Equatable {
    var token: String
    var user: User
}

struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var notes: String?
    var done: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, notes, done
        case createdAt = "created_at"
    }
}

struct TaskPage: Codable, Sendable, Equatable {
    var items: [TaskItem]
    var page: Int
    var limit: Int
    var total: Int
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items, page, limit, total
        case hasMore = "has_more"
    }
}

struct DeletedCount: Codable, Sendable, Equatable {
    var deleted: Int
}

struct ErrorBody: Codable, Sendable, Equatable {
    var error: String
    var message: String
    var fields: [String: String]?
}

enum StatusFilter: String, CaseIterable, Sendable, Identifiable {
    case all, open, done

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .open: "Open"
        case .done: "Done"
        }
    }
}

/// Why a call failed, in terms a screen can act on.
enum APIError: Error, Equatable {
    /// The session is over and could not be renewed; the user must sign in again.
    case signedOut
    case accountDisabled
    /// The server refused the request and said why.
    case rejected(status: Int, code: String, message: String, fields: [String: String])
    case server(status: Int)
    case unreachable
    /// The response was not what the API promises.
    case malformed

    var message: String {
        switch self {
        case .signedOut:
            "Your session ended. Sign in again."
        case .accountDisabled:
            "This account is disabled."
        case .rejected(_, _, let message, _):
            message
        case .server(let status):
            "The server had a problem (\(status)). Try again."
        case .unreachable:
            "Can't reach the server. Check your connection and try again."
        case .malformed:
            "The server sent something unexpected. Try again."
        }
    }

    /// True when the app can no longer act for this user.
    var endsSession: Bool {
        self == .signedOut || self == .accountDisabled
    }
}
