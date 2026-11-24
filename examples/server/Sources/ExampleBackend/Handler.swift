import Foundation
import OSLog
import OpenAPIRuntime
import SwiftCommons

/// The operations of `openapi.yaml`, answered from the in-memory `Store`.
struct Handler: APIProtocol {
    private static let logger = Logger.forType(subsystem: "ExampleServer", Handler.self)

    let store: Store
    let signer: TokenSigner
    let now: @Sendable () -> Date

    // MARK: Session

    func createSession(
        _ input: Operations.CreateSession.Input
    ) async throws -> Operations.CreateSession.Output {
        guard case .json(let credentials) = input.body else {
            return .unprocessableContent(.init(body: .json(Self.error("invalid_body", "A JSON body is required"))))
        }
        var fields: [String: String] = [:]
        if credentials.email.trimmingCharacters(in: .whitespaces).isEmpty {
            fields["email"] = "Enter your email"
        }
        if credentials.password.isEmpty {
            fields["password"] = "Enter your password"
        }
        guard fields.isEmpty else {
            return .unprocessableContent(
                .init(body: .json(Self.error("invalid_fields", "Some fields need attention", fields: fields))))
        }
        do {
            let (session, account) = try await store.signIn(
                email: credentials.email.trimmingCharacters(in: .whitespaces), password: credentials.password)
            let token = try signer.token(account: account, session: session, now: now())
            Self.logger.infoPublic("Signed in account=\(account.id)")
            let cookie = "\(AuthMiddleware.cookieName)=\(session); Path=/; HttpOnly; SameSite=Lax"
            return .ok(
                .init(
                    headers: .init(setCookie: cookie),
                    body: .json(.init(token: token, user: Self.user(account)))))
        } catch StoreError.accountDisabled {
            Self.logger.infoPublic("Sign-in refused: account disabled")
            return .forbidden(.init(body: .json(Self.error("account_disabled", "This account is disabled"))))
        } catch {
            Self.logger.infoPublic("Sign-in refused: invalid credentials")
            return .unauthorized(
                .init(body: .json(Self.error("invalid_credentials", "The email or password is wrong"))))
        }
    }

    func deleteSession(
        _ input: Operations.DeleteSession.Input
    ) async throws -> Operations.DeleteSession.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        await store.signOut(session: caller.session)
        Self.logger.infoPublic("Signed out account=\(caller.account)")
        return .noContent
    }

    func refreshSession(
        _ input: Operations.RefreshSession.Input
    ) async throws -> Operations.RefreshSession.Output {
        guard let caller = Caller.current,
            let account = try? await store.account(forSession: caller.session)
        else {
            return .unauthorized(Self.signedOut)
        }
        guard !account.disabled else {
            Self.logger.infoPublic("Refresh refused: account=\(account.id) disabled")
            return .forbidden(.init(body: .json(Self.error("account_disabled", "This account is disabled"))))
        }
        let token = try signer.token(account: account, session: caller.session, now: now())
        Self.logger.infoPublic("Refreshed token account=\(account.id)")
        return .ok(.init(body: .json(.init(token: token, user: Self.user(account)))))
    }

    func getMe(_ input: Operations.GetMe.Input) async throws -> Operations.GetMe.Output {
        guard let caller = Caller.current,
            let account = try? await store.account(forSession: caller.session)
        else {
            return .unauthorized(Self.signedOut)
        }
        return .ok(.init(body: .json(Self.user(account))))
    }

    // MARK: Tasks

    func listTasks(_ input: Operations.ListTasks.Input) async throws -> Operations.ListTasks.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        let page = input.query.page
        let limit = input.query.limit
        guard page >= 1 else {
            return .badRequest(.init(body: .json(Self.error("invalid_query", "page must be at least 1"))))
        }
        guard (1...100).contains(limit) else {
            return .badRequest(
                .init(body: .json(Self.error("invalid_query", "limit must be between 1 and 100"))))
        }
        let done: Bool? =
            switch input.query.status {
            case .all: nil
            case .open: false
            case .done: true
            }
        let result = await store.page(account: caller.account, done: done, page: page, limit: limit)
        return .ok(
            .init(
                body: .json(
                    .init(
                        items: result.items.map(Self.item),
                        page: page,
                        limit: limit,
                        total: result.total,
                        hasMore: page * limit < result.total
                    ))))
    }

    func createTask(_ input: Operations.CreateTask.Input) async throws -> Operations.CreateTask.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        guard case .json(let new) = input.body else {
            return .unprocessableContent(.init(body: .json(Self.error("invalid_body", "A JSON body is required"))))
        }
        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let problem = Self.titleProblem(title) else {
            let task = await store.addTask(
                title: title, notes: new.notes, account: caller.account, now: now())
            Self.logger.infoPublic("Created task=\(task.id) account=\(caller.account)")
            return .created(.init(body: .json(Self.item(task))))
        }
        return .unprocessableContent(
            .init(
                body: .json(
                    Self.error("invalid_fields", "Some fields need attention", fields: ["title": problem]))))
    }

    func deleteAllTasks(
        _ input: Operations.DeleteAllTasks.Input
    ) async throws -> Operations.DeleteAllTasks.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        let deleted = await store.deleteAllTasks(account: caller.account)
        Self.logger.infoPublic("Deleted \(deleted) tasks account=\(caller.account)")
        return .ok(.init(body: .json(.init(deleted: deleted))))
    }

    func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        guard let task = try? await store.task(input.path.id, account: caller.account) else {
            return .notFound(Self.noSuchTask)
        }
        return .ok(.init(body: .json(Self.item(task))))
    }

    func updateTask(_ input: Operations.UpdateTask.Input) async throws -> Operations.UpdateTask.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        guard case .json(let changes) = input.body else {
            return .unprocessableContent(.init(body: .json(Self.error("invalid_body", "A JSON body is required"))))
        }
        let title = changes.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, let problem = Self.titleProblem(title) {
            return .unprocessableContent(
                .init(
                    body: .json(
                        Self.error("invalid_fields", "Some fields need attention", fields: ["title": problem]))))
        }
        guard
            let task = try? await store.updateTask(
                input.path.id, account: caller.account, title: title, notes: changes.notes,
                done: changes.done)
        else {
            return .notFound(Self.noSuchTask)
        }
        Self.logger.infoPublic("Updated task=\(task.id) account=\(caller.account)")
        return .ok(.init(body: .json(Self.item(task))))
    }

    func deleteTask(_ input: Operations.DeleteTask.Input) async throws -> Operations.DeleteTask.Output {
        guard let caller = Caller.current else {
            return .unauthorized(Self.signedOut)
        }
        do {
            try await store.deleteTask(input.path.id, account: caller.account)
        } catch {
            return .notFound(Self.noSuchTask)
        }
        Self.logger.infoPublic("Deleted task=\(input.path.id) account=\(caller.account)")
        return .noContent
    }

    // MARK: Shapes

    private static var signedOut: Components.Responses.Unauthorized {
        .init(body: .json(error("missing_token", "A bearer token is required")))
    }

    private static var noSuchTask: Components.Responses.NotFound {
        .init(body: .json(error("task_not_found", "No such task")))
    }

    private static func titleProblem(_ title: String) -> String? {
        if title.isEmpty {
            return "Enter a title"
        }
        if title.count > 80 {
            return "Use 80 characters or fewer"
        }
        return nil
    }

    private static func error(
        _ code: String, _ message: String, fields: [String: String]? = nil
    ) -> Components.Schemas.ErrorBody {
        .init(error: code, message: message, fields: fields.map { .init(additionalProperties: $0) })
    }

    private static func user(_ account: Account) -> Components.Schemas.User {
        .init(id: account.id, name: account.name, email: account.email)
    }

    private static func item(_ task: TaskRecord) -> Components.Schemas.TaskItem {
        .init(id: task.id, title: task.title, notes: task.notes, done: task.done, createdAt: task.createdAt)
    }
}
