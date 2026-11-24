@_exported import ExtensionKit
import Foundation

/// amoo's flow-extension request and reply, carrying this bridge's run state.
public typealias ExtensionRequest = FlowRequest<BridgeState>
public typealias ExtensionReply = FlowReply<BridgeState>

/// What the bridge keeps between calls in one amoo run. amoo stores it and sends it back unread.
public struct BridgeState: Codable, Sendable, Equatable {
    public var configPath: String
    public var port: Int
    public var platform: Platform
    public var sessionId: String
    /// `moq.mark` names → server timestamps, for later steps' `since`.
    public var marks: [String: Double]?
    /// What `GET /_admin/version` reported at flow start; `nil` in state from an older bridge,
    /// which skips the check.
    public var capabilities: [String]?

    public init(
        configPath: String, port: Int, platform: Platform, sessionId: String,
        marks: [String: Double]? = nil, capabilities: [String]? = nil
    ) {
        self.configPath = configPath
        self.port = port
        self.platform = platform
        self.sessionId = sessionId
        self.marks = marks
        self.capabilities = capabilities
    }
}
