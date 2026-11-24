import ArgumentParser
import AuthBridge
import Foundation

@main
struct AmooExtAuth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amoo-ext-auth",
        abstract: "Account fixtures for amoo flows, on an identity-provider emulator or a backend's test routes.",
        discussion: """
            amoo runs describe, flow_start, step and flow_end for auth.* flow steps, with one JSON \
            request on stdin and one JSON reply on stdout (amoo's flow-extension protocol 1). \
            Steps: \(AuthHandler.steps.map { "auth.\($0)" }.joined(separator: ", ")), each taking {email}. \
            flow_end puts every changed account back. Providers: the Firebase Auth emulator, or the \
            app backend's own test routes (test-routes), which can also give each run a session of \
            its own on the backend. emit writes XCUITest code for test-routes.
            """
    )

    /// amoo passes the verb as the first argument; the request body names it too.
    @Argument(help: "describe, flow_start, step, flow_end or emit.")
    var verb: String

    func run() async throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if verb == "emit" {
            let request = try JSONDecoder().decode(AuthEmitRequest.self, from: input)
            print(String(decoding: try encoder.encode(AuthEmitter().handle(request)), as: UTF8.self))
            return
        }
        let request = try JSONDecoder().decode(AuthRequest.self, from: input)
        let reply = try await AuthHandler().handle(request)
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    }
}
