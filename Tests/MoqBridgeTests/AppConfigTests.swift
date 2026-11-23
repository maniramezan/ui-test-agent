import Foundation
import Testing

@testable import MoqBridge

@Suite("AppConfig")
struct AppConfigTests {
    @Test("The example config loads and validates")
    func exampleConfigLoads() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "examples/moq.json")
        let config = try AppConfig.load(from: url)
        #expect(config.app == "sample")
        #expect(try config.platformConfig(for: .android).appHost == "10.0.2.2")
        #expect(try config.platformConfig(for: .ios).requireSession)
        #expect(try !config.platformConfig(for: .android).requireSession)
    }

    @Test("A valid config has no problems")
    func validConfig() {
        #expect(Fixtures.config().problems().isEmpty)
    }

    @Test("A platform without {{sessionId}} is rejected")
    func missingSessionPlaceholder() {
        let config = Fixtures.config(launchEnvironment: ["APP_BASE_URL": "{{baseURL}}"])
        #expect(config.problems().contains { $0.contains("never join its session") })
    }

    @Test("Unknown placeholders are rejected")
    func unknownPlaceholder() {
        let config = Fixtures.config(launchEnvironment: [
            "APP_SESSION": "{{sessionId}}", "APP_PORT": "{{port}}",
        ])
        #expect(config.problems() == ["platforms.android.launchEnvironment.APP_PORT uses unknown placeholder {{port}}",
                                      "platforms.ios.launchEnvironment.APP_PORT uses unknown placeholder {{port}}"])
    }

    @Test("Unknown platforms and a bad port are reported")
    func badPlatformAndPort() {
        var config = Fixtures.config()
        config.server.port = 0
        config.platforms["web"] = config.platforms["ios"]
        let problems = config.problems()
        #expect(problems.contains("server.port 0 is outside 1-65535"))
        #expect(problems.contains { $0.hasPrefix("platforms.web is not one of") })
    }

    @Test("adminAuth decodes each kind and rejects unknown ones")
    func adminAuthCoding() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AdminAuth.self, from: Data(#"{"kind":"none"}"#.utf8)) == .none)
        #expect(
            try decoder.decode(AdminAuth.self, from: Data(#"{"kind":"bearer","tokenEnv":"T"}"#.utf8))
                == .bearer(tokenEnv: "T"))
        #expect(
            try decoder.decode(
                AdminAuth.self, from: Data(#"{"kind":"apiKey","header":"X-Admin-Key","valueEnv":"K"}"#.utf8))
                == .apiKey(header: "X-Admin-Key", valueEnv: "K"))
        #expect(throws: DecodingError.self) {
            try decoder.decode(AdminAuth.self, from: Data(#"{"kind":"basic"}"#.utf8))
        }
    }
}

@Suite("LaunchTemplate")
struct LaunchTemplateTests {
    @Test("Renders known placeholders and leaves literal values alone")
    func render() throws {
        let rendered = try LaunchTemplate.render(
            ["A": "{{baseURL}}/v1", "B": "{{sessionId}}", "C": "plain"],
            values: ["baseURL": "http://10.0.2.2:8080", "sessionId": "abc"]
        )
        #expect(rendered == ["A": "http://10.0.2.2:8080/v1", "B": "abc", "C": "plain"])
    }

    @Test("Throws on a placeholder with no value")
    func missingValue() {
        #expect(throws: BridgeError.unknownPlaceholder(name: "port")) {
            try LaunchTemplate.render("{{port}}", values: [:])
        }
    }
}
