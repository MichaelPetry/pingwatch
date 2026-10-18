import Foundation

/// Wraps `/sbin/ping -c 1` and returns the RTT in ms, or nil when there is no reply.
///
/// macOS `ping` has a ~1s floor for unreachable hosts regardless of `-W`,
/// so a watchdog kills the child if it runs past `watchdogMs`.
enum Pinger {
    static func ping(_ host: String, watchdogMs: Int) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/ping")
                process.arguments = ["-c", "1", "-W", "250", host]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: nil)
                    return
                }
                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(watchdogMs) * 1_000_000)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: Self.parseRtt(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Pulls `time=12.3 ms` out of ping's output.
    static func parseRtt(_ text: String) -> Double? {
        guard let range = text.range(of: "time=") else { return nil }
        let digits = text[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
        return Double(digits)
    }
}
