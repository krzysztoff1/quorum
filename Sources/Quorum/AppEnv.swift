import Foundation

enum AppEnv {
    static let isDev = Bundle.main.bundleIdentifier == nil
    static let replayFixture: String? = isDev ? ProcessInfo.processInfo.environment["QUORUM_REPLAY_FIXTURE"] : nil
}
