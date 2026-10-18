import Foundation
import AppKit
import Combine

/// One ping result; nil = no reply.
struct Sample: Sendable, Equatable {
    let rtt: Double?
}

enum HostStatus: Equatable {
    case up, degraded, down
}

/// Per-host state, observed by its row view.
@MainActor
final class HostState: ObservableObject, Identifiable {
    let id: Int
    let name: String
    let label: String

    @Published var samples: [Sample] = []   // oldest → newest, capped at 600
    @Published var status: HostStatus = .up
    @Published var lastRtt: Double?
    @Published var address = "resolving…"   // what the Resolver is actually pinging
    @Published var fails = 0
    var downSince: Date?

    init(id: Int, name: String, label: String) {
        self.id = id
        self.name = name
        self.label = label
    }

    func reset() {
        samples = []
        status = .up
        lastRtt = nil
        fails = 0
        downSince = nil
    }

    /// Stats over the last `n` samples.
    func windowStats(n: Int) -> (min: Double?, avg: Double?, max: Double?, lossPct: Double) {
        let win = Array(samples.suffix(n))
        guard !win.isEmpty else { return (nil, nil, nil, 0) }
        let vals = win.compactMap { $0.rtt }
        let lossPct = Double(win.count - vals.count) / Double(win.count) * 100.0
        guard !vals.isEmpty else { return (nil, nil, nil, lossPct) }
        let avg = vals.reduce(0, +) / Double(vals.count)
        return (vals.min(), avg, vals.max(), lossPct)
    }
}

/// Drives the ping sweep and owns all host states.
@MainActor
final class Monitor: ObservableObject {
    @Published var hosts: [HostState] = []
    @Published var intervalMs: Int = 1000 {
        didSet { reschedule() }
    }
    @Published var windowN: Int = 60
    @Published var tick = 0
    @Published var elapsedSec = 0
    @Published var hostsPath = ""
    @Published var pingMode = "starting…"

    private var sweepTimer: Timer?
    private var elapsedTimer: Timer?
    private var refreshTimer: Timer?
    private var sweeping = false
    private var started = false
    private var resolvedInitial = false
    private var nextId = 0
    private let startDate = Date()
    private let rawPinger = ICMPPinger()
    private let resolver = Resolver()
    /// Blocks App Nap so sweeps keep their schedule while backgrounded.
    private var sleepActivity: NSObjectProtocol?

    var windowSeconds: Int {
        max(1, Int((Double(windowN) * Double(intervalMs) / 1000.0).rounded()))
    }

    var upCount: Int { hosts.filter { $0.status == .up }.count }
    var degradedCount: Int { hosts.filter { $0.status == .degraded }.count }
    var downCount: Int { hosts.filter { $0.status == .down }.count }

    func start(hostsPath: String) {
        guard !started else { return }
        started = true
        self.hostsPath = hostsPath
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Continuous ICMP monitoring")
        do {
            try rawPinger.open()
            pingMode = "raw ICMP"
        } catch {
            pingMode = "fallback: /sbin/ping"
        }
        hosts = HostFile.load(path: hostsPath).map { entry in
            let host = HostState(id: nextId, name: entry.name, label: entry.label)
            nextId += 1
            return host
        }
        reschedule()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsedSec = Int(Date().timeIntervalSince(self.startDate))
            }
        }
        // Background DNS refresh (IP churn, retry of failed names). Sweeps
        // read the cache only, so this never gates or stalls a ping cycle.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let names = self.hosts.map(\.name)
                await self.resolver.refresh(names)
                await self.updateAddresses(names)
            }
        }
        // Resolve once before the first sweep: hostnames with no address yet
        // would otherwise show DOWN while DNS is still in flight.
        Task { [weak self] in
            guard let self else { return }
            let names = self.hosts.map(\.name)
            await self.resolver.resolve(names, force: false)
            await self.updateAddresses(names)
            self.resolvedInitial = true
            self.doSweep()
        }
    }

    /// Add from the UI: parses "name [label]", persists to the hosts file,
    /// and resolves immediately so the row reports on the next sweep.
    func addHost(raw: String) {
        let parts = raw.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first,
              !hosts.contains(where: { $0.name == first }) else { return }
        let name = String(first)
        let label = parts.dropFirst().joined(separator: " ")
        HostFile.add(HostFile.Entry(name: name, label: label), to: hostsPath)
        let host = HostState(id: nextId, name: name, label: label)
        nextId += 1
        hosts.append(host)
        Task { [weak self] in
            guard let self else { return }
            await self.resolver.resolve([name], force: true)
            await self.updateAddresses([name])
            self.doSweep()
        }
    }

    func removeHost(id: Int) {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { return }
        let name = hosts[i].name
        hosts.remove(at: i)
        HostFile.remove(name: name, from: hostsPath)
        Task { await resolver.forget(name) }
    }

    func clear() {
        hosts.forEach { $0.reset() }
    }

    /// Mirror the resolver's current pick onto each row (called after every
    /// resolve — startup, add, background refresh).
    private func updateAddresses(_ names: [String]) async {
        let addrs = await resolver.display(for: names)
        for host in hosts {
            host.address = addrs[host.name] ?? "resolving…"
        }
    }

    private func reschedule() {
        sweepTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.doSweep() }
        }
        timer.tolerance = 0.05
        sweepTimer = timer
    }

    private func doSweep() {
        guard !sweeping, resolvedInitial, !hosts.isEmpty else { return }
        sweeping = true
        let names = hosts.map(\.name)

        if rawPinger.isOpen {
            // One shared socket pair; all hosts in a single parallel sweep.
            let waitMs = max(80, intervalMs - 60)
            let pinger = rawPinger
            Task { [weak self] in
                guard let self else { return }
                let targets = await self.resolver.targets(for: names)
                let byName = await Task.detached(priority: .userInitiated) {
                    pinger.sweep(targets, waitMs: waitMs)
                }.value
                self.apply(byName)
                self.sweeping = false
            }
            return
        }

        // Legacy fallback: one /sbin/ping subprocess per host.
        let watchdogMs = max(150, min(800, intervalMs - 100))
        Task { [weak self] in
            var byName = [String: Double?]()
            await withTaskGroup(of: (String, Double?).self) { group in
                for name in names {
                    group.addTask { (name, await Pinger.ping(name, watchdogMs: watchdogMs)) }
                }
                for await (name, rtt) in group {
                    byName[name] = rtt
                }
            }
            self?.apply(byName)
            self?.sweeping = false
        }
    }

    /// Name-keyed (not index-keyed): hosts can be added or removed while a
    /// sweep is in flight.
    private func apply(_ results: [String: Double?]) {
        for host in hosts {
            let rtt = results[host.name] ?? nil
            host.samples.append(Sample(rtt: rtt))
            if host.samples.count > 600 {
                host.samples.removeFirst(host.samples.count - 600)
            }
            host.fails = rtt == nil ? host.fails + 1 : 0

            let wasDown = host.status == .down
            let isDown = rtt == nil && host.fails >= 3
            if isDown && !wasDown {
                host.downSince = Date()
                alertDown(host)
            }
            if wasDown && !isDown {
                host.downSince = nil
                alertUp(host)
            }
            if isDown {
                host.status = .down
            } else if rtt == nil {
                host.status = .degraded   // 1–2 consecutive misses, not yet "down"
            } else {
                host.status = host.windowStats(n: windowN).lossPct > 5.0 ? .degraded : .up
            }
            host.lastRtt = rtt
        }
        tick += 1
    }

    // MARK: - alerts

    private func alertDown(_ host: HostState) {
        alert("PingWatch", "\(host.name) is DOWN (3 missed pings)", sound: "Basso")
    }

    private func alertUp(_ host: HostState) {
        alert("PingWatch", "\(host.name) is back UP", sound: "Glass")
    }

    private func alert(_ title: String, _ message: String, sound: String) {
        NSSound(named: NSSound.Name(sound))?.play()
        // osascript works without an app bundle; reaped via terminationHandler
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\""]
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.terminationHandler = { _ in }
        } catch { }
    }
}
