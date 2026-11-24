import ArgumentParser
import ExampleBackend
import Hummingbird

@main
struct ExampleServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "example-server",
        abstract: "The local backend of ExampleApp: the API in examples/openapi.yaml over seeded, in-memory data.",
        discussion: """
            POST /_test/reset restores the seed data. PUT and DELETE /_test/accounts/<email>/disabled \
            disable and re-enable an account. These routes are outside the spec on purpose.
            """
    )

    @Option(name: .long, help: "Address to listen on.")
    var host = "127.0.0.1"

    @Option(name: .long, help: "Port to listen on.")
    var port = 8081

    @Option(name: .long, help: "Seconds a bearer token lasts. A short value makes the app refresh often.")
    var tokenLifetime: Double = 3600

    func run() async throws {
        let router = try Backend.router(store: Store(), tokenLifetime: tokenLifetime)
        let application = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port), serverName: "example-server")
        )
        try await application.runService()
    }
}
