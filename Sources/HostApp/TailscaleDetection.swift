import Foundation
import SharedUtilities
#if os(macOS)
import Darwin
#endif

/// Tailscale identity for this host, when the device is signed in to a tailnet.
struct TailscaleConnectionInfo: Equatable {
    let ipAddress: String
    let dnsName: String?

    var connectHost: String {
        dnsName ?? ipAddress
    }

    var connectAddress: String {
        "\(connectHost):\(RemoteDesktopConstants.defaultSignalingPort)"
    }

    /// Tailscale Serve terminates HTTPS on the tailnet hostname and proxies to
    /// the loopback browser service. `127.0.0.1` must never be shown as the
    /// remote Safari address because it points back to the phone or tablet.
    var browserControlURL: String? {
        guard let dnsName, !dnsName.isEmpty else { return nil }
        return "https://\(dnsName)"
    }
}

/// Detects whether this Mac is on a Tailscale tailnet and returns its addressable identity.
/// Prefers the CLI status JSON (richest data), falls back to `tailscale ip`, then a raw scan of
/// the 100.64.0.0/10 CGNAT range on local interfaces — the last path works in sandboxed builds
/// where launching the CLI isn't permitted.
func getTailscaleConnectionInfo() -> TailscaleConnectionInfo? {
    if let statusOutput = runTailscaleCommand(["status", "--json"]),
       let data = statusOutput.data(using: .utf8),
       let payload = try? JSONDecoder().decode(TailscaleStatusPayload.self, from: data),
       let device = payload.device,
       let ipAddress = device.tailscaleIPs?.first(where: { tsIsValidIPAddress($0) }) {
        let dnsName = device.dnsName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return TailscaleConnectionInfo(ipAddress: ipAddress, dnsName: dnsName)
    }

    if let ipOutput = runTailscaleCommand(["ip", "-4"]),
       let ipAddress = ipOutput
        .components(separatedBy: .newlines)
        .first(where: { !$0.isEmpty && tsIsValidIPAddress($0) }) {
        return TailscaleConnectionInfo(ipAddress: ipAddress, dnsName: nil)
    }

    if let ip = getTailscaleIPFromInterfaces() {
        return TailscaleConnectionInfo(ipAddress: ip, dnsName: nil)
    }

    return nil
}

// MARK: - Internals

private struct TailscaleStatusPayload: Decodable {
    struct SelfDevice: Decodable {
        let dnsName: String?
        let tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
            case tailscaleIPs = "TailscaleIPs"
        }
    }

    let device: SelfDevice?

    enum CodingKeys: String, CodingKey {
        case device = "Self"
    }
}

private let tailscaleBinaryPaths: [String] = [
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
]

private let tailscaleCommandTimeout: DispatchTimeInterval = .seconds(3)

private func findTailscaleBinary() -> String? {
    tailscaleBinaryPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func isSandboxedApp() -> Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
}

private func runTailscaleCommand(_ arguments: [String]) -> String? {
    guard !isSandboxedApp() else { return nil }
    guard let binaryPath = findTailscaleBinary() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    let outputReader = DispatchGroup()
    let output = LockedData()
    outputReader.enter()
    DispatchQueue.global(qos: .utility).async {
        output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
        outputReader.leave()
    }

    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }

    do {
        try process.run()
    } catch {
        outputPipe.fileHandleForWriting.closeFile()
        outputReader.wait()
        return nil
    }

    guard termination.wait(timeout: .now() + tailscaleCommandTimeout) == .success else {
        process.terminate()
        if termination.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + .milliseconds(500))
        }
        outputPipe.fileHandleForWriting.closeFile()
        outputReader.wait()
        return nil
    }

    outputReader.wait()
    guard process.terminationStatus == 0 else { return nil }

    let data = output.value
    guard let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty else {
        return nil
    }

    // The CLI sometimes prints diagnostic text on stdout while still exiting 0
    // (e.g. "not running"). Reject obvious non-data outputs so we don't poison UI.
    let normalized = output.lowercased()
    let looksLikeError = ["error", "failed", "not running", "permission denied", "cannot", "unable"]
        .contains { normalized.contains($0) }
    if looksLikeError { return nil }

    return output
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }
}

private func getTailscaleIPFromInterfaces() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let addr = ptr.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                          &buf, socklen_t(buf.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: buf)
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "100",
              let second = Int(parts[1]),
              second >= 64, second <= 127 else { continue }
        return ip
    }
    return nil
}

private func tsIsValidIPAddress(_ address: String) -> Bool {
    let ipPattern = "^(\\d{1,3}\\.){3}\\d{1,3}$"
    guard let regex = try? NSRegularExpression(pattern: ipPattern) else { return false }
    let range = NSRange(address.startIndex..<address.endIndex, in: address)
    return regex.firstMatch(in: address, range: range) != nil
}
