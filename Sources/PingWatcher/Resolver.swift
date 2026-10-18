import Foundation
import Darwin

/// A host's chosen ping target. Literal IPs never touch DNS (inet_pton fast path).
enum HostAddr: Sendable {
    case v4(UInt32)      // in_addr s_addr, network byte order
    case v6([UInt8])     // 16 bytes

    /// The address as a C struct, for sendto / inet_ntop.
    var in6: in6_addr {
        var a = in6_addr()
        if case .v6(let bytes) = self {
            withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
        }
        return a
    }

    /// Printable form with family tag, for the UI.
    var display: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch self {
        case .v4(let sAddr):
            var a4 = in_addr(s_addr: sAddr)
            inet_ntop(AF_INET, &a4, &buf, socklen_t(INET_ADDRSTRLEN))
            return "IPv4 " + String(cString: buf)
        case .v6:
            var a6 = in6
            inet_ntop(AF_INET6, &a6, &buf, socklen_t(INET6_ADDRSTRLEN))
            return "IPv6 " + String(cString: buf)
        }
    }
}

/// Maps host names to addresses off the ping cycle: at startup, when hosts are
/// added or removed, and on a background refresh timer (IP churn + failed-name
/// retry). Sweeps only read the cached table — a hung DNS server can never
/// stall a ping cycle.
actor Resolver {
    private struct Entry {
        let addr: HostAddr?
        let nextRetry: Date   // when the background refresh may re-try
    }
    private var table: [String: Entry] = [:]

    /// Background refresh of names whose cached address (or failed lookup)
    /// has aged out. Never called from the sweep path.
    func refresh(_ names: [String]) {
        resolve(names, force: false)
    }

    /// Resolve now; `force` bypasses the cache (host just added).
    func resolve(_ names: [String], force: Bool) {
        let now = Date()
        var seen = Set<String>()
        for name in names where !seen.contains(name) {
            seen.insert(name)
            if !force, let entry = table[name], entry.nextRetry > now { continue }
            let addr = Self.lookup(name)
            // Unresolved names retry quickly; resolved ones ride the
            // background refresh at its own pace.
            let ttl: TimeInterval = (addr == nil) ? 5 : 30
            table[name] = Entry(addr: addr, nextRetry: now.addingTimeInterval(ttl))
        }
    }

    /// Sweep input — cache only, no DNS. Unresolved names are omitted.
    func targets(for names: [String]) -> [(name: String, addr: HostAddr)] {
        names.compactMap { name in table[name]?.addr.map { (name, $0) } }
    }

    /// What each row should show as its target: "IPv4 1.2.3.4",
    /// "no address" (lookup failed, retry pending), or "resolving…".
    func display(for names: [String]) -> [String: String] {
        var out = [String: String](minimumCapacity: names.count)
        for name in names {
            if let addr = table[name]?.addr {
                out[name] = addr.display
            } else if table[name] != nil {
                out[name] = "no address"
            } else {
                out[name] = "resolving…"
            }
        }
        return out
    }

    func forget(_ name: String) { table[name] = nil }

    /// Literal IP first (zero DNS round-trips), then getaddrinfo preferring v4.
    private static func lookup(_ name: String) -> HostAddr? {
        var a4 = in_addr()
        if inet_pton(AF_INET, name, &a4) == 1 { return .v4(a4.s_addr) }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, name, &a6) == 1 {
            return .v6(withUnsafeBytes(of: a6) { Array($0) })
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var resPtr: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &resPtr) == 0, let first = resPtr else { return nil }
        defer { freeaddrinfo(first) }
        var v6: HostAddr?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let ai = info.pointee
            if ai.ai_family == AF_INET, let raw = ai.ai_addr {
                let saddr = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                return .v4(saddr)
            }
            if ai.ai_family == AF_INET6, v6 == nil, let raw = ai.ai_addr {
                v6 = .v6(raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                })
            }
            cursor = ai.ai_next
        }
        return v6
    }
}
