import Foundation
import OSLog
import Observation
import SwiftCommons

/// The task list: what is loaded, under which filter, and what last went wrong.
@MainActor
@Observable
final class TasksModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private static let logger = Logger.forType(subsystem: "ExampleApp", TasksModel.self)

    private(set) var phase = Phase.loading
    private(set) var items: [TaskItem] = []
    private(set) var total = 0
    private(set) var hasMore = false
    private(set) var filter = StatusFilter.all
    private(set) var loadingMore = false
    /// Why the last delete or change failed; the list itself is still shown.
    var actionError: String?

    private var page = 1
    private let client: APIClient
    private let session: SessionModel

    init(session: SessionModel) {
        self.session = session
        client = session.client
    }

    func load() async {
        phase = .loading
        await fetchFirstPage(refreshing: false)
    }

    func refresh() async {
        await fetchFirstPage(refreshing: true)
    }

    func apply(_ newFilter: StatusFilter) async {
        guard newFilter != filter else {
            return
        }
        filter = newFilter
        await load()
    }

    func loadMore() async {
        guard hasMore, !loadingMore else {
            return
        }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        Self.logger.infoPublic("Loading page \(next) filter=\(filter.rawValue)")
        do {
            let result = try await client.tasks(status: filter, page: next, refreshing: false)
            page = next
            items.append(contentsOf: result.items)
            total = result.total
            hasMore = result.hasMore
            Self.logger.infoPublic("Loaded page \(next): \(result.items.count) tasks")
        } catch {
            report(error, action: "loadMore")
        }
    }

    func add(_ task: TaskItem) {
        guard filter != .done else {
            return
        }
        items.insert(task, at: 0)
        total += 1
    }

    func replace(_ task: TaskItem) {
        guard let index = items.firstIndex(where: { $0.id == task.id }) else {
            return
        }
        items[index] = task
    }

    func delete(_ task: TaskItem) async {
        Self.logger.infoPublic("Deleting task=\(task.id)")
        do {
            try await client.deleteTask(id: task.id)
            items.removeAll { $0.id == task.id }
            total = max(0, total - 1)
            Self.logger.infoPublic("Deleted task=\(task.id)")
        } catch {
            report(error, action: "delete task=\(task.id)")
        }
    }

    func deleteAll() async {
        Self.logger.infoPublic("Deleting all tasks")
        do {
            let deleted = try await client.deleteAllTasks()
            Self.logger.infoPublic("Deleted \(deleted) tasks")
            await load()
        } catch {
            report(error, action: "deleteAll")
        }
    }

    private func fetchFirstPage(refreshing: Bool) async {
        Self.logger.infoPublic("Loading tasks filter=\(filter.rawValue) refreshing=\(refreshing)")
        do {
            let result = try await client.tasks(status: filter, page: 1, refreshing: refreshing)
            page = 1
            items = result.items
            total = result.total
            hasMore = result.hasMore
            phase = .loaded
            Self.logger.infoPublic("Loaded \(result.items.count) of \(result.total) tasks")
        } catch let error as APIError where error.endsSession {
            session.sessionEnded(error)
        } catch {
            Self.logger.error("Loading tasks failed", error: error, context: "feature=tasks action=load")
            phase = .failed((error as? APIError)?.message ?? APIError.malformed.message)
        }
    }

    private func report(_ error: any Error, action: String) {
        Self.logger.error("Task action failed", error: error, context: "feature=tasks action=\(action)")
        let failure = error as? APIError ?? .malformed
        if failure.endsSession {
            session.sessionEnded(failure)
        } else {
            actionError = failure.message
        }
    }
}
