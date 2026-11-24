import Foundation

/// A seeded account. Passwords are fixture values of a fictional app, not secrets.
struct Account: Sendable, Equatable {
    var id: String
    var name: String
    var email: String
    var password: String
    var disabled: Bool
}

struct TaskRecord: Sendable, Equatable {
    var id: String
    var title: String
    var notes: String?
    var done: Bool
    var createdAt: Date
}

enum StoreError: Error, Equatable {
    case invalidCredentials
    case accountDisabled
    case unknownSession
    case taskNotFound
}

/// Everything the backend knows, held in memory and restored to the same seed by `reset()`,
/// so every test run can start from identical data.
public actor Store {
    public static let seededTaskCount = 25

    private var accounts: [Account] = []
    /// Session id → account id.
    private var sessions: [String: String] = [:]
    /// Account id → tasks, newest first.
    private var tasks: [String: [TaskRecord]] = [:]
    private var createdTasks = 0

    public init() {
        accounts = Self.seedAccounts
        tasks = Self.seedTasks
    }

    public func reset() {
        accounts = Self.seedAccounts
        tasks = Self.seedTasks
        sessions = [:]
        createdTasks = 0
    }

    // MARK: Sessions

    func signIn(email: String, password: String) throws -> (session: String, account: Account) {
        guard
            let account = accounts.first(where: { $0.email.lowercased() == email.lowercased() }),
            account.password == password
        else {
            throw StoreError.invalidCredentials
        }
        guard !account.disabled else {
            throw StoreError.accountDisabled
        }
        let session = UUID().uuidString.lowercased()
        sessions[session] = account.id
        return (session, account)
    }

    func signOut(session: String) {
        sessions[session] = nil
    }

    /// The account a session belongs to. A disabled account keeps its session, so a refresh can
    /// answer "disabled" instead of "unknown".
    func account(forSession session: String) throws -> Account {
        guard let id = sessions[session], let account = accounts.first(where: { $0.id == id }) else {
            throw StoreError.unknownSession
        }
        return account
    }

    func setDisabled(_ disabled: Bool, email: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.email.lowercased() == email.lowercased() })
        else {
            return false
        }
        accounts[index].disabled = disabled
        return true
    }

    // MARK: Tasks

    func page(
        account: String, done filter: Bool?, page: Int, limit: Int
    ) -> (items: [TaskRecord], total: Int) {
        let all = (tasks[account] ?? []).filter { filter == nil || $0.done == filter }
        let start = (page - 1) * limit
        guard start < all.count else {
            return ([], all.count)
        }
        return (Array(all[start..<min(start + limit, all.count)]), all.count)
    }

    func task(_ id: String, account: String) throws -> TaskRecord {
        guard let task = tasks[account]?.first(where: { $0.id == id }) else {
            throw StoreError.taskNotFound
        }
        return task
    }

    func addTask(title: String, notes: String?, account: String, now: Date) -> TaskRecord {
        createdTasks += 1
        let task = TaskRecord(
            id: "task-new-\(createdTasks)", title: title, notes: notes, done: false, createdAt: now)
        tasks[account, default: []].insert(task, at: 0)
        return task
    }

    func updateTask(
        _ id: String, account: String, title: String?, notes: String?, done: Bool?
    ) throws -> TaskRecord {
        guard let index = tasks[account]?.firstIndex(where: { $0.id == id }) else {
            throw StoreError.taskNotFound
        }
        var task = tasks[account, default: []][index]
        task.title = title ?? task.title
        task.notes = notes ?? task.notes
        task.done = done ?? task.done
        tasks[account, default: []][index] = task
        return task
    }

    func deleteTask(_ id: String, account: String) throws {
        guard let index = tasks[account]?.firstIndex(where: { $0.id == id }) else {
            throw StoreError.taskNotFound
        }
        tasks[account, default: []].remove(at: index)
    }

    func deleteAllTasks(account: String) -> Int {
        let count = tasks[account]?.count ?? 0
        tasks[account] = []
        return count
    }

    // MARK: Seed

    private static let seedAccounts = [
        Account(
            id: "user-1", name: "Alex Example", email: "user@example.com",
            password: "example-password", disabled: false),
        Account(
            id: "user-2", name: "Sam Example", email: "second@example.com",
            password: "example-password", disabled: false),
        Account(
            id: "user-3", name: "Dana Example", email: "disabled@example.com",
            password: "example-password", disabled: true),
    ]

    /// 2026-01-01T00:00:00Z. Seeded tasks are one hour apart from here, so their order is fixed.
    private static let seedEpoch = Date(timeIntervalSince1970: 1_767_225_600)

    private static var seedTasks: [String: [TaskRecord]] {
        let first = (1...seededTaskCount).map { number in
            TaskRecord(
                id: String(format: "task-%03d", number),
                title: "Task \(number)",
                notes: number.isMultiple(of: 5) ? "Notes for task \(number)" : nil,
                done: number.isMultiple(of: 3),
                createdAt: seedEpoch.addingTimeInterval(Double(number) * 3600)
            )
        }
        return ["user-1": first.reversed(), "user-2": [], "user-3": []]
    }
}
