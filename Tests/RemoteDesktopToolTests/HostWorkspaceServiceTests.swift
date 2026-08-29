#if os(macOS)
import XCTest
import Foundation
@testable import HostApp
@testable import SharedProtocol

private final class WorkspaceTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

final class HostWorkspaceServiceTests: XCTestCase {
    func testDiscoveryFindsGitWorkspaceAndReturnsSafeRoots() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Projects/Vamp", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        // Discovery runs `git` for metadata. An empty `.git` directory is not a
        // repo, and those processes can stall past a short XCTest timeout on a
        // loaded CI runner. Initialize a real repository instead.
        try gitInit(at: project)
        try Data("// test workspace\n".utf8).write(to: project.appendingPathComponent("Package.swift"))
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(hostID: UUID(), homePath: root.path)
        let expectation = expectation(description: "workspace discovery")
        let workspacesBox = WorkspaceTestBox<[RemoteWorkspace]>([])
        let rootsBox = WorkspaceTestBox<[WorkspaceBrowseRoot]>([])

        service.listWorkspaces(refresh: true) { discovered, browseRoots, errorMessage in
            XCTAssertNil(errorMessage)
            workspacesBox.set(discovered)
            rootsBox.set(browseRoots)
            expectation.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10),
            .completed,
            "workspace discovery should finish on a tiny git project"
        )

        let workspaces = workspacesBox.value
        let roots = rootsBox.value
        let canonicalProjectPath = try XCTUnwrap(service.validatedWorkingDirectory(project.path))
        let vamp = try XCTUnwrap(workspaces.first { $0.path == canonicalProjectPath })
        XCTAssertEqual(vamp.kind, .gitRepository)
        XCTAssertEqual(vamp.gitInfo?.projectHints, ["Swift", "Swift Package"])
        XCTAssertEqual(roots.first?.name, "Home")
        XCTAssertTrue(roots.contains { $0.name == "Projects" })
    }

    func testDirectoryBrowsingAndWorkingDirectoryBoundary() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let one = projects.appendingPathComponent("One", isDirectory: true)
        try fileManager.createDirectory(at: one, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(hostID: UUID(), homePath: root.path)
        let expectation = expectation(description: "directory listing")
        let entriesBox = WorkspaceTestBox<[WorkspaceDirectoryEntry]>([])
        service.listDirectory(path: projects.path) { _, listed, errorMessage in
            XCTAssertNil(errorMessage)
            entriesBox.set(listed)
            expectation.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)

        let entries = entriesBox.value
        XCTAssertEqual(entries.map(\.name), ["One"])
        XCTAssertEqual(service.validatedWorkingDirectory("~/Projects"), projects.path)
        XCTAssertNil(service.validatedWorkingDirectory("/tmp"))
        XCTAssertNil(service.validatedWorkingDirectory(root.path + "/../outside"))
    }

    func testDirectoryBrowsingDoesNotWaitForBackgroundDiscovery() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("VampWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = HostWorkspaceService(
            hostID: UUID(),
            homePath: root.path,
            discoveryDelayForTesting: 1
        )
        let discoveryStarted = expectation(description: "discovery completes")
        service.listWorkspaces(refresh: true) { _, _, _ in discoveryStarted.fulfill() }

        let browseReturned = expectation(description: "interactive browse returns immediately")
        service.listDirectory(path: root.path) { _, _, errorMessage in
            XCTAssertNil(errorMessage)
            browseReturned.fulfill()
        }

        wait(for: [browseReturned], timeout: 0.5)
        XCTAssertEqual(XCTWaiter.wait(for: [discoveryStarted], timeout: 10), .completed)
    }

    private func gitInit(at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "init", "--quiet"]
        process.environment = [
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git init should succeed for workspace discovery fixtures")
    }
}
#endif
