import Foundation
import Darwin

/// Non-root ICMP echo pinger on Apple's dgram ICMP sockets.
///
/// Wire behavior verified empirically on macOS 27 without root:
/// - `AF_INET/SOCK_DGRAM/IPPROTO_ICMP` and `AF_INET6/…/IPPROTO_ICMPV6` open without root.
/// - Send: a bare ICMP (v4) or ICMPv6 (v6) message; the explicit identifier survives on the wire.
/// - v4 receive: the full IP packet is delivered — parse the IP header and keep proto == 1.
/// - v6 receive: the bare ICMPv6 message is delivered (no IPv6 header) — keep type == 129.
/// - The socket delivers every echo reply bound for this host (other pingers included),
///   so replies must be filtered by (identifier, sequence).
/// - The v4 checksum must be a correct big-endian RFC 1071 checksum or the kernel
///   silently drops the request. (Little-endian word order = no replies at all.)
///
/// Never touches DNS: callers hand it addresses resolved by `Resolver`, so a
/// slow resolver can't stall a sweep. One sweep at a time; the caller
/// (Monitor) serializes.
final class ICMPPinger: @unchecked Sendable {
    enum PingerError: Error {
        case socket(Int32)
    }

    private var v4fd: Int32 = -1
    private var v6fd: Int32 = -1
    private let id: UInt16
    private var seqCounter: UInt16 = 0

    private struct Pending {
        let name: String
        let sent: Date
    }

    private var v6SourceCache: [String: in6_addr] = [:]

    init() {
        // Non-zero id; kept as-is by the kernel, used to filter our replies.
        id = UInt16.random(in: 0x1000...0xFFFF)
    }

    deinit {
        if v4fd >= 0 { close(v4fd) }
        if v6fd >= 0 { close(v6fd) }
    }

    var isOpen: Bool { v4fd >= 0 }

    /// Opens the sockets. Throws when the kernel refuses non-root ICMP (older macOS).
    func open() throws {
        let v4 = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard v4 >= 0 else { throw PingerError.socket(Int32(errno)) }
        v4fd = v4
        let v6 = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        if v6 >= 0 {
            var one: Int32 = 1
            setsockopt(v6, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            v6fd = v6
        }
    }

    // MARK: - sweep

    /// Pings every pre-resolved target in parallel over the shared sockets,
    /// waiting up to `waitMs`. Returns RTT in ms keyed by name;
    /// nil = no reply in time.
    func sweep(_ targets: [(name: String, addr: HostAddr)], waitMs: Int) -> [String: Double?] {
        var out = [String: Double?](minimumCapacity: targets.count)
        for t in targets { out[t.name] = nil }

        var pending = [UInt16: Pending]()
        for t in targets {
            seqCounter = seqCounter &+ 1
            let seq = seqCounter
            let sent = Date()
            let sentOk: Bool
            switch t.addr {
            case .v4(let sAddr):
                sentOk = sendV4(addr: in_addr(s_addr: sAddr), seq: seq)
            case .v6(let bytes):
                sentOk = sendV6(dst: Self.v6Address(bytes), seq: seq)
            }
            if sentOk {
                pending[seq] = Pending(name: t.name, sent: sent)
            }
        }
        guard !pending.isEmpty else { return out }

        var pollfds: [pollfd] = []
        if v4fd >= 0 { pollfds.append(pollfd(fd: v4fd, events: Int16(POLLIN), revents: 0)) }
        if v6fd >= 0 { pollfds.append(pollfd(fd: v6fd, events: Int16(POLLIN), revents: 0)) }
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)

        while !pending.isEmpty {
            let remaining = Int(deadline.timeIntervalSinceNow * 1000.0)
            guard remaining > 0 else { break }
            let ready = poll(&pollfds, UInt32(pollfds.count), Int32(min(remaining, 50)))
            guard ready > 0 else { continue }
            for pf in pollfds where pf.revents & Int16(POLLIN) != 0 {
                if pf.fd == v4fd {
                    receiveV4(pending: &pending, out: &out)
                } else {
                    receiveV6(pending: &pending, out: &out)
                }
            }
        }
        return out
    }

    // MARK: - sending

    private func sendV4(addr: in_addr, seq: UInt16) -> Bool {
        var msg = [UInt8](repeating: 0, count: 24)
        msg[0] = 8                                  // ICMP echo request
        msg[1] = 0
        msg[4] = UInt8(id >> 8); msg[5] = UInt8(id & 0xFF)     // network order
        msg[6] = UInt8(seq >> 8); msg[7] = UInt8(seq & 0xFF)
        for i in 8..<24 { msg[i] = 0xAB }
        let c = Self.checksum(msg)                  // MUST be big-endian word order
        msg[2] = UInt8(c >> 8); msg[3] = UInt8(c & 0xFF)

        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = addr
        return msg.withUnsafeBytes { raw in
            withUnsafePointer(to: &sin) { sinPtr in
                sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sinSock in
                    sendto(v4fd, raw.baseAddress, msg.count, 0,
                           sinSock, socklen_t(MemoryLayout<sockaddr_in>.size)) >= 0
                }
            }
        }
    }

    private func sendV6(dst: in6_addr, seq: UInt16) -> Bool {
        var msg = [UInt8](repeating: 0, count: 24)
        msg[0] = 128                                // ICMPv6 echo request
        msg[1] = 0
        msg[4] = UInt8(id >> 8); msg[5] = UInt8(id & 0xFF)
        msg[6] = UInt8(seq >> 8); msg[7] = UInt8(seq & 0xFF)
        for i in 8..<24 { msg[i] = 0xAB }

        // Pseudo-header checksum. The kernel-picked source is learned best-effort;
        // the kernel turns out to be lenient (even an all-zero source gets through),
        // but compute it properly when we know the source.
        let src = v6Source(for: dst)
        var pseudo = [UInt8](repeating: 0, count: 40)
        withUnsafeBytes(of: src) { s in pseudo.replaceSubrange(0..<16, with: s) }
        withUnsafeBytes(of: dst) { d in pseudo.replaceSubrange(16..<32, with: d) }
        let len32 = UInt32(msg.count).bigEndian
        withUnsafeBytes(of: len32) { l in pseudo.replaceSubrange(32..<36, with: l) }
        pseudo[39] = 58                             // next header = ICMPv6

        var sum = 0
        var i = 0
        while i + 1 < 40 { sum += Int(pseudo[i]) << 8 | Int(pseudo[i + 1]); i += 2 }
        i = 0
        while i + 1 < msg.count { sum += Int(msg[i]) << 8 | Int(msg[i + 1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        let c = UInt16(~sum & 0xFFFF)
        msg[2] = UInt8(c >> 8); msg[3] = UInt8(c & 0xFF)

        var sin6 = sockaddr_in6()
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_addr = dst
        return msg.withUnsafeBytes { raw in
            withUnsafePointer(to: &sin6) { sinPtr in
                sinPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sinSock in
                    sendto(v6fd, raw.baseAddress, msg.count, 0,
                           sinSock, socklen_t(MemoryLayout<sockaddr_in6>.size)) >= 0
                }
            }
        }
    }

    // MARK: - receiving

    private func receiveV4(pending: inout [UInt16: Pending], out: inout [String: Double?]) {
        var buf = [UInt8](repeating: 0, count: 512)
        let bufCount = buf.count
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buf.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromSock in
                    recvfrom(v4fd, raw.baseAddress, bufCount, 0, fromSock, &fromLen)
                }
            }
        }
        guard n >= 28, buf[0] >> 4 == 4 else { return }        // IPv4
        let ihl = Int(buf[0] & 0x0F) * 4
        guard buf[9] == 1, n >= ihl + 8 else { return }        // proto ICMP
        guard buf[ihl] == 0 else { return }                    // echo reply
        guard UInt16(buf[ihl + 4]) << 8 | UInt16(buf[ihl + 5]) == id else { return }
        let seq = UInt16(buf[ihl + 6]) << 8 | UInt16(buf[ihl + 7])
        guard let p = pending.removeValue(forKey: seq) else { return }   // stale/foreign
        out[p.name] = Date().timeIntervalSince(p.sent) * 1000.0
    }

    private func receiveV6(pending: inout [UInt16: Pending], out: inout [String: Double?]) {
        var buf = [UInt8](repeating: 0, count: 512)
        let bufCount = buf.count
        var from = sockaddr_in6()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let n = buf.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { fromSock in
                    recvfrom(v6fd, raw.baseAddress, bufCount, 0, fromSock, &fromLen)
                }
            }
        }
        guard n >= 8, buf[0] == 129 else { return }            // bare ICMPv6 echo reply
        guard UInt16(buf[4]) << 8 | UInt16(buf[5]) == id else { return }
        let seq = UInt16(buf[6]) << 8 | UInt16(buf[7])
        guard let p = pending.removeValue(forKey: seq) else { return }
        out[p.name] = Date().timeIntervalSince(p.sent) * 1000.0
    }

    // MARK: - helpers

    /// RFC 1071 ones' complement checksum over big-endian 16-bit words.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += Int(bytes[i]) << 8 | Int(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += Int(bytes[i]) }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }

    /// 16 raw bytes (from `Resolver`) → `in6_addr`.
    static func v6Address(_ bytes: [UInt8]) -> in6_addr {
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: bytes) }
        return a
    }

    /// Best-effort learn of the source address the kernel will pick for `dst`
    /// (UDP probe on a scratch socket — same source selection). Falls back to
    /// all-zeros, which the kernel accepts anyway.
    private func v6Source(for dst: in6_addr) -> in6_addr {
        var key = ""
        withUnsafeBytes(of: dst) { p in
            for b in p { key += String(format: "%02x", b) }
        }
        if let cached = v6SourceCache[key] { return cached }

        var src = in6_addr()
        if isAllZero(dst) || isLoopback6(dst) {
            src = loopback6()
            v6SourceCache[key] = src
            return src
        }
        var d6 = sockaddr_in6()
        d6.sin6_family = sa_family_t(AF_INET6)
        d6.sin6_addr = dst
        let u = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard u >= 0 else { return src }
        defer { close(u) }
        var dummy: UInt8 = 1
        withUnsafePointer(to: &d6) { dp in
            dp.withMemoryRebound(to: sockaddr.self, capacity: 1) { d6Sock in
                _ = sendto(u, &dummy, 1, 0, d6Sock, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        var learned = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        withUnsafeMutablePointer(to: &learned) { lp in
            lp.withMemoryRebound(to: sockaddr.self, capacity: 1) { lpSock in
                _ = getsockname(u, lpSock, &len)
            }
        }
        if !isAllZero(learned.sin6_addr) {
            src = learned.sin6_addr
            v6SourceCache[key] = src
        }
        return src
    }

    private func isAllZero(_ a: in6_addr) -> Bool {
        withUnsafeBytes(of: a) { p in p.allSatisfy { $0 == 0 } }
    }

    private func isLoopback6(_ a: in6_addr) -> Bool {
        withUnsafeBytes(of: a) { p in
            p.dropLast().allSatisfy { $0 == 0 } && p[p.count - 1] == 1
        }
    }

    private func loopback6() -> in6_addr {
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { p in p[p.count - 1] = 1 }
        return a
    }
}
