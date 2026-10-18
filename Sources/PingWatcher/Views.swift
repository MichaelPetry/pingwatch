import SwiftUI

// MARK: - dashboard

struct DashboardView: View {
    @EnvironmentObject var m: Monitor
    @State private var showingAdd = false
    private let pal = Palette.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            board
            footer
        }
        .padding(18)
        .frame(minWidth: 980, minHeight: 420)
        .background(pal.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            LiveDot(tick: m.tick)
            Text("PingWatch")
                .font(.system(size: 17, weight: .semibold))
            Text(m.pingMode)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(m.pingMode == "raw ICMP" ? pal.line : pal.yellow)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill((m.pingMode == "raw ICMP" ? pal.line : pal.yellow).opacity(0.15)))
            summary
            Text("t+\(m.elapsedSec)s")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(pal.dim)
            Spacer()
            Text("interval")
                .font(.system(size: 12))
                .foregroundColor(pal.dim)
            Picker("", selection: $m.intervalMs) {
                Text("250 ms").tag(250)
                Text("500 ms").tag(500)
                Text("1 s").tag(1000)
                Text("2 s").tag(2000)
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            Text("window")
                .font(.system(size: 12))
                .foregroundColor(pal.dim)
            Picker("", selection: $m.windowN) {
                Text("30").tag(30)
                Text("60").tag(60)
                Text("120").tag(120)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            Button {
                showingAdd = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundColor(pal.line)
            .help("Add a host")
            .popover(isPresented: $showingAdd, arrowEdge: .bottom) {
                AddHostPopover().environmentObject(m)
            }
            Button("Clear") { m.clear() }
        }
    }

    private var summary: some View {
        (Text("\(m.upCount)").foregroundColor(pal.green) + Text(" up").foregroundColor(pal.dim)
            + Text("  ·  ").foregroundColor(pal.dim)
            + Text("\(m.degradedCount)").foregroundColor(pal.yellow) + Text(" degraded").foregroundColor(pal.dim)
            + Text("  ·  ").foregroundColor(pal.dim)
            + Text("\(m.downCount)").foregroundColor(pal.red) + Text(" down").foregroundColor(pal.dim))
            .font(.system(size: 13, design: .monospaced))
    }

    // MARK: board

    private var board: some View {
        VStack(spacing: 0) {
            columnHeaders
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Rectangle().fill(pal.border).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    if m.hosts.isEmpty {
                        Text("No hosts — press + or put one per line in hosts.txt")
                            .font(.system(size: 13))
                            .foregroundColor(pal.dim)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(Array(m.hosts.enumerated()), id: \.element.id) { idx, host in
                        row(host)
                        if idx < m.hosts.count - 1 {
                            Rectangle().fill(pal.border.opacity(0.55)).frame(height: 1)
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.border, lineWidth: 1))
    }

    private var columnHeaders: some View {
        HStack(spacing: 12) {
            Text("").frame(width: 11)
            Text("HOST").frame(width: 200, alignment: .leading)
            Text("RTT").frame(width: 88, alignment: .leading)
            Text("LAST \(m.windowSeconds) S")
            Text("MIN / AVG / MAX").frame(width: 170, alignment: .trailing)
            Text("").frame(width: 16)
        }
        .font(.system(size: 11, weight: .semibold))
        .kerning(0.8)
        .foregroundColor(pal.dim)
    }

    private func row(_ host: HostState) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor(host.status))
                .frame(width: 11, height: 11)
                .shadow(color: dotColor(host.status).opacity(0.7), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !host.label.isEmpty {
                    Text(host.label)
                        .font(.system(size: 11))
                        .foregroundColor(pal.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 200, alignment: .leading)

            rttCell(host)
                .frame(width: 88, alignment: .leading)

            RTTChart(samples: Array(host.samples.suffix(m.windowN)))
                .frame(height: 44)

            statsCell(host)
                .frame(width: 170, alignment: .trailing)

            DeleteButton(id: host.id, name: host.name)
                .frame(width: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func rttCell(_ host: HostState) -> some View {
        if host.status == .down {
            let secs = host.downSince.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
            Text("down \(secs)s")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(pal.red)
        } else if host.lastRtt == nil {
            Text("no reply")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(pal.yellow)
        } else if let v = host.lastRtt {
            Text(fmtRtt(v) + " ms")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
        }
    }

    private func statsCell(_ host: HostState) -> some View {
        let s = host.windowStats(n: m.windowN)
        let mm: String
        if let mn = s.min, let av = s.avg, let mx = s.max {
            mm = "\(fmtRtt(mn)) / \(fmtRtt(av)) / \(fmtRtt(mx))"
        } else {
            mm = "– / – / –"
        }
        let lossColor: Color = s.lossPct == 0 ? pal.dim : (s.lossPct > 5 ? pal.red : pal.yellow)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(mm)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(pal.dim)
            Text(String(format: "loss %.1f%%", s.lossPct))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(lossColor)
        }
    }

    private func dotColor(_ status: HostStatus) -> Color {
        switch status {
        case .up: return pal.green
        case .degraded: return pal.yellow
        case .down: return pal.red
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 18) {
            legendSwatch(pal.line, label: "RTT (ms, auto-scaled)", kind: .line)
            legendSwatch(pal.red, label: "lost ping", kind: .notch)
            legendSwatch(pal.red.opacity(0.25), label: "down (no reply)", kind: .shade)
            Spacer()
            Text("hosts: " + (m.hostsPath.isEmpty ? "none found" : m.hostsPath))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(pal.dim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func legendSwatch(_ color: Color, label: String, kind: LegendKind) -> some View {
        HStack(spacing: 7) {
            switch kind {
            case .line:
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 22, height: 3)
            case .notch:
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 4, height: 10)
            case .shade:
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(pal.red.opacity(0.4), lineWidth: 1))
                    .frame(width: 22, height: 10)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(pal.dim)
        }
    }
}

enum LegendKind { case line, notch, shade }

// MARK: - add host

struct AddHostPopover: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private let pal = Palette.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add host")
                .font(.system(size: 13, weight: .semibold))
            TextField("host or IP  (label optional)", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(submit)
            HStack {
                Text("e.g. 8.8.8.8 Google DNS")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(pal.dim)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func submit() {
        m.addHost(raw: text)
        dismiss()
    }
}

// MARK: - row delete

struct DeleteButton: View {
    @EnvironmentObject var m: Monitor
    let id: Int
    let name: String
    @State private var hovering = false

    var body: some View {
        Button {
            m.removeHost(id: id)
        } label: {
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(hovering ? Palette.shared.red : Palette.shared.dim)
        .opacity(hovering ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help("Remove \(name)")
    }
}

// MARK: - live pulse

struct LiveDot: View {
    let tick: Int
    @State private var pulsing = true

    var body: some View {
        Circle()
            .fill(Palette.shared.green)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 1.0 : 1.7)
            .opacity(pulsing ? 1.0 : 0.35)
            .onChange(of: tick) { _, _ in
                pulsing = false
                withAnimation(.easeOut(duration: 0.35)) { pulsing = true }
            }
    }
}

// MARK: - RTT chart

struct RTTChart: View {
    let samples: [Sample]

    var body: some View {
        Canvas { context, size in
            let pal = Palette.shared
            let n = samples.count
            guard n >= 2 else { return }
            let w = size.width
            let h = size.height
            let step = w / CGFloat(n - 1)
            let vals = samples.compactMap { $0.rtt }
            let yMax = niceMax((vals.max() ?? 4.0) * 1.12)
            func yPos(_ v: Double) -> CGFloat {
                h - 8 - CGFloat(v / yMax) * (h - 18)
            }

            // midline grid
            var grid = Path()
            let gy = yPos(yMax * 0.5)
            grid.move(to: CGPoint(x: 0, y: gy))
            grid.addLine(to: CGPoint(x: w, y: gy))
            context.stroke(grid, with: .color(.white.opacity(0.10)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            // shade down-runs (2+ consecutive misses)
            var i = 0
            while i < n {
                guard samples[i].rtt == nil else { i += 1; continue }
                let start = i
                while i < n && samples[i].rtt == nil { i += 1 }
                if i - start >= 2 {
                    let rect = CGRect(x: CGFloat(start) * step - step / 2, y: 0,
                                      width: CGFloat(i - start) * step, height: h)
                    context.fill(Path(rect), with: .color(pal.red.opacity(0.13)))
                }
            }

            // RTT line + fill, per contiguous run
            var runs: [[(x: CGFloat, v: Double)]] = []
            var run: [(x: CGFloat, v: Double)] = []
            for (idx, s) in samples.enumerated() {
                if let v = s.rtt {
                    run.append((CGFloat(idx) * step, v))
                } else if !run.isEmpty {
                    runs.append(run)
                    run = []
                }
            }
            if !run.isEmpty { runs.append(run) }

            for r in runs {
                if r.count == 1 {
                    let dot = CGRect(x: r[0].x - 1.5, y: yPos(r[0].v) - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(pal.line))
                } else {
                    var line = Path()
                    line.move(to: CGPoint(x: r[0].x, y: yPos(r[0].v)))
                    for p in r.dropFirst() {
                        line.addLine(to: CGPoint(x: p.x, y: yPos(p.v)))
                    }
                    context.stroke(line, with: .color(pal.line),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    var area = Path()
                    area.move(to: CGPoint(x: r[0].x, y: h - 2))
                    for p in r {
                        area.addLine(to: CGPoint(x: p.x, y: yPos(p.v)))
                    }
                    area.addLine(to: CGPoint(x: r[r.count - 1].x, y: h - 2))
                    area.closeSubpath()
                    context.fill(area, with: .color(pal.line.opacity(0.13)))
                }
            }

            // lost-ping notches
            for (idx, s) in samples.enumerated() where s.rtt == nil {
                let x = CGFloat(idx) * step
                let width = max(3.0, step - 1.0)
                let rect = CGRect(x: x - width / 2, y: h - 3, width: width, height: 5)
                context.fill(Path(rect), with: .color(pal.red))
            }

            // scale label
            let label = yMax >= 10 ? String(format: "%.0f ms", yMax) : String(format: "%.1f ms", yMax)
            context.draw(
                Text(label).font(.system(size: 10)).foregroundColor(pal.dim),
                at: CGPoint(x: 4, y: 2),
                anchor: .topLeading
            )

            // "now" edge
            context.fill(Path(CGRect(x: w - 1, y: 0, width: 1, height: h)),
                         with: .color(.white.opacity(0.22)))
        }
    }
}

// MARK: - helpers

/// Rounds up to a 1/2/5×10^k "nice" axis max.
func niceMax(_ v: Double) -> Double {
    guard v > 0 else { return 5 }
    let p = pow(10.0, floor(log10(v)))
    for m in [1.0, 2.0, 5.0, 10.0] where m * p >= v {
        return m * p
    }
    return 10 * p
}

func fmtRtt(_ v: Double) -> String {
    v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}
