# PingWatch

macOS ping monitor for network upgrades: pings every host in a list once per
interval and draws a rolling RTT graph per host with loss marks.

- **green dot** = up · **yellow** = degraded (>5% loss in window) · **red** = down
  (3 consecutive missed pings)
- **red notch** on a graph = one lost ping; **red band** = host down
- sound + macOS notification on up↔down transitions
- interval and window adjustable live in the header
- **+/−** buttons add and remove hosts (persisted back to the hosts file,
  comments preserved)
- each row shows the label and the exact IPv4/IPv6 address being pinged
  (`resolving…` / `no address` until DNS settles)

## Build & run

```sh
cd ~/QWEN/pingtester
swift build -c release
.build/release/PingWatcher                      # uses ./hosts.txt
.build/release/PingWatcher /path/to/hosts.txt   # or an explicit file
```

## hosts.txt format

One host per line, optional label after the name, `#` comments:

```
192.168.1.1   Gateway
8.8.8.8       Google DNS
```

## Notes

- Pings via **raw ICMP echo** (own packets, own sockets — no root on macOS 27):
  one shared socket pair, all hosts in a single parallel sweep, RTT measured to
  sub-millisecond. If the kernel ever refuses non-root ICMP sockets (older macOS),
  it falls back to `/sbin/ping -c 1` per host with a watchdog.
- DNS runs **outside the ping cycle** — at startup, on host add/remove, and on a
  background refresh (~30 s) — so a hung resolver can never stall a sweep.
  Literal IPs never touch DNS at all.
- App Nap is disabled while running, so backgrounded windows keep pinging.
- UI mockup with simulated data: `mockup/index.html`.
- Runs as a plain executable (generic dock icon). Notifications are routed
  through `osascript`; packaging it as a `.app` bundle later would make them
  come from the app itself.
