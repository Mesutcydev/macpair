#if os(macOS)
import XCTest
@testable import HostApp
import SharedProtocol

final class HostAgentSemanticServiceTests: XCTestCase {
    func testPromptIsSeparatedFromFlagsForEveryProvider() {
        let prompt = "--not-a-provider-flag"
        for provider in AgentProviderKind.allCases {
            let launch = HostAgentSemanticService.launch(provider: provider, prompt: prompt, previousSessionID: nil)
            XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--", prompt], "\(provider.rawValue)")
            XCTAssertFalse(
                launch.arguments.dropLast(2).contains(prompt),
                "\(provider.rawValue) must not splice the prompt into flags"
            )
        }
    }

    func testOpenCodeMatchesLinuxOneShotJSONRun() {
        let launch = HostAgentSemanticService.launch(provider: .openCode, prompt: "hello", previousSessionID: "ses_1")
        XCTAssertEqual(launch.executable, "opencode")
        XCTAssertEqual(launch.arguments, ["run", "--format", "json", "--session", "ses_1", "--", "hello"])
        XCTAssertFalse(launch.arguments.contains("--auto"))
    }

    func testCodexResumeKeepsJSONFlagsBeforePromptSeparator() {
        let launch = HostAgentSemanticService.launch(provider: .codex, prompt: "resume me", previousSessionID: "thread-1")
        XCTAssertEqual(launch.arguments, [
            "exec", "--dangerously-bypass-approvals-and-sandbox",
            "resume", "thread-1", "--json", "--skip-git-repo-check", "--", "resume me"
        ])
    }
}
#endif
