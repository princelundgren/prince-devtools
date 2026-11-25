---
status: building
verified: 2026-11-25
governs:
  - PrinceDevTools/**
  - PrinceDevToolsCore/**
  - .github/workflows/release.yml
---

# PrinceDevTools: design

A public, open-source macOS menu bar app that gathers a developer's everyday status and one-click
actions in one panel, in place of separate apps. This design covers the app itself and its first
tool, **system health**; each later tool gets its own design.

## Why

Developers who run many coding agents at once see them eat RAM, disk and CPU. One glance at the
menu bar should say the system is fine; when it isn't, the panel should say what is wrong and which
process is behind it. Separate menu bar apps for each job are annoying to run side by side, and a
single app must not become overwhelming (owner).

## Goals

- **One menu bar icon** that changes only when something needs attention.
- **A panel of cards**, one per metric, with a message area at the top for problems.
- **System health:** memory pressure, CPU averaged over minutes, free disk space, and process
  count against the macOS limit, each against a threshold the user can change.
- **When red:** the message names the problem and the process most responsible, with an **Open
  Activity Monitor** button (owner).
- **Very cheap to run** (owner): no idle CPU, a wakeup budget measured before each release, low
  RAM, no leaks. See "Efficiency".
- Public, MIT, notarized, updates through Sparkle.
- **For later tools** (owner): a tool belongs if you glance at it or act on it with one click;
  tools arrive one at a time, easiest first, each made well.

## Non-goals

- History, graphs or trends.
- Notifications: the icon and the panel are the signal.
- Stopping or killing processes from the panel (owner): Activity Monitor does that.
- Grouping an agent with its helper processes; the culprit is one process by name.
- Typed or pasted tools (JSON, Base64, JWT): they belong in a web tool, not a menu bar panel
  (owner).
- The later tools; the shell only has to make adding one a new card, message source, Settings pane
  and module.
- Watching other users' processes: the process meter counts the current user's, which is the
  limit their agents hit.

## Anti-goals

- **A monitor that costs what it monitors**: any idle CPU, a wakeup rate above the budget, RAM that
  grows over time.
- **Crying wolf**: red on a CPU spike, on Apple's yellow memory pressure, on a partial CPU window,
  or a message that flickers at a threshold.
- **A crowded panel**: text walls, many colours, controls nobody uses.

## Constraints

- macOS 26.0 or later, Swift 6.2 tools, as prince-clockin (`PrinceClockIn/project.yml`,
  `PrinceClockInCore/Package.swift`).
- No third-party runtime dependency but Sparkle.
- Developer ID distribution, not the App Store: the later keep-awake tool needs a privileged
  helper, which the App Store sandbox can't run (prince-sleepless design).
- Public repository: no personal machines, accounts or private infrastructure in code, docs or
  commits.

## Approaches

1. **prince-clockin's template, a module per tool.** One repo, an XcodeGen app target and one
   `PrinceDevToolsCore` Swift package with a library target per tool. **Chosen** (owner,
   2026-11-24): the smallest thing built right, on a release pipeline that already works. A tool's
   module can move to its own package later if a standalone app ever needs it.
2. **A package and repo per tool, the app assembling them.** Shareable from day one, but several
   repos and coordinated releases before a second tool exists. Rejected for now.
3. **Fork exelban/stats (MIT).** It already reads RAM, CPU and disk, but it puts one menu bar
   item per metric and has its own look, against one icon and cards, and a fork tracks a large
   upstream forever. Rejected; its code may be read for reference, with credit for anything taken.

## The app

### Repository and build

- `princelundgren/prince-devtools`, public, MIT, laid out as prince-clockin:
  `PrinceDevTools/project.yml` (XcodeGen) and `PrinceDevToolsCore/` (SwiftPM).
- `PrinceDevToolsCore` targets: `SystemHealth` (readings, averaging, threshold evaluation, no
  AppKit), `PanelKit` (the tones, the card, message and footer views and the menu bar label shared
  by every tool, and the Settings text for launch at login and the version). Tests per target.
- CI, CodeQL, the Claude review workflow, Dependabot and `release.yml` adapted from
  prince-clockin. CI and the release's test job run on GitHub-hosted macOS runners, as
  prince-sleepless decided for a public repo.
- **No entitlements.** The app only opens other apps, so the release keeps prince-clockin's
  signature and hardened-runtime checks and drops its Apple Events check.
- **Releases:** Developer ID signing, `notarytool`, Sparkle feed at
  `https://updates.princelundgren.com/princedevtools/appcast.xml` (the host's prefixes carry no
  hyphen). Sparkle settings as prince-clockin's `Info.plist`: signed feed required, verification
  before extraction, daily automatic checks, no system profiling. Sparkle's pin is bumped by hand
  from its GitHub releases, since Dependabot doesn't see it.
- **Signing, notarization and Sparkle keys are reused** from the maintainer's existing release
  setup and read at release time through a short-lived OIDC credential; none is stored in this
  repository, unless that route isn't ready for the first release, when they are set as `release`
  environment secrets, as prince-clockin's are today.
- **The update upload** uses an OIDC role of its own, confined to the `princedevtools/` prefix,
  this repository's `release` environment and `v*` tags, so one app's CI can't overwrite another's
  appcast.
- **Release gates before any secret**, as prince-sleepless: the `release` environment deploys
  only from `v*` tags, a ruleset limits `v*` tags to the admin, and outside contributors' pull
  requests wait for approval. The later keep-awake tool will put a root helper behind these
  updates.

### Menu bar icon

- `NSStatusItem` with an `NSPopover` hosting SwiftUI, as prince-clockin's
  `StatusItemController.swift` and `AppDelegate.swift`, so its macOS 27 popover fixes carry over.
- Two states: **normal** (a template SF Symbol) and **attention** (a different symbol, also red)
  while the message area holds any message. Messages, not metrics, define attention, so every
  later tool raises it the same way. The symbol differs, not only the colour. The status item's
  accessibility label names the first message. No text in the menu bar.
- Opening the app while it runs opens the panel, so a menu bar that hides the icon doesn't lose
  it.

### Panel

```
┌──────────────────────────────────────┐
│ ▲ Memory pressure is red             │  message area: only while there are messages
│   Top of your processes: claude 4.1 GB│
│ ▲ CPU avg 5 min is 91 %              │
│   Top of your processes: node 340 %  │
│              [Open Activity Monitor] │
├──────────────────────────────────────┤
│ ┌─ Memory ─────────┐ ┌─ CPU ───────┐ │
│ │ ▲ Red            │ │ ▲ 91 %      │ │
│ │ Swap 8.3 GB      │ │ avg 5 min   │ │
│ └──────────────────┘ └─────────────┘ │
│ ┌─ Disk ───────────┐ ┌─ Processes ─┐ │
│ │ ● 70 GB free     │ │ ● 755/4000  │ │
│ │                  │ │ ▬▬▬───────  │ │
│ └──────────────────┘ └─────────────┘ │
├──────────────────────────────────────┤
│ ⚙                                  ⏻ │
└──────────────────────────────────────┘
```

- **Message area at the top** (owner chose top or bottom; top is this design's call: the problem
  is the first thing seen). One message per cause, in a fixed order: memory, disk, processes, CPU,
  thermal; later tools' messages follow in panel order. A fixed order needs no severity model and
  keeps the area from reshuffling. **One Open Activity Monitor button** at the foot of the area,
  shown while any memory, CPU, process or thermal message is present. A message disappears when its
  cause ends.
- **Message wording** for the lines the mockup doesn't show: disk "28 GB free on the startup
  disk", processes "3,300 of 4,000 processes in use".
- **Cards** in a two-column grid; each has a title, a status symbol and one or two lines. States:
  green, red, memory's yellow, and **"Not known yet"** (neutral, never green or red) until a card
  has its first reading. Each state has its own symbol, never colour alone; colours use
  prince-clockin's tokens with their Increase Contrast variants. Each card is one VoiceOver
  element naming its value and state.
- **The process card** shows the count over the limit with a thin linear gauge under it (owner:
  "a meter").
- **Footer** as the Prince popover style: Settings left, Quit right. Sparkle's "update ready" row
  sits where prince-clockin puts it.
- **Settings in a window**, not inside the popover: thresholds for several tools won't fit a
  popover. A sidebar pane per tool, plus General (launch at login through `SMAppService.mainApp`,
  off by default) and About (the version and Check for Updates).
- **Units:** disk in decimal GB as Finder counts (`ByteCountFormatStyle` `.file`), memory and swap in
  `.memory` style, each formatted for the user's locale.

## System health

### Metrics

| Card | Reading | Source | Red when (default) |
|---|---|---|---|
| Memory | Apple's memory pressure; swap used as the second line | `kern.memorystatus_vm_pressure_level`, read when an event below arrives and on the 60 s tick; `DispatchSource.makeMemoryPressureSource` as the trigger; swap from `sysctlbyname("vm.swapusage")` → `xsw_usage.xsu_used` (bytes) | pressure is critical (owner: fine unless at max) |
| CPU | average CPU % over the window, all cores | cumulative ticks from `host_statistics(HOST_CPU_LOAD_INFO)` | average over 5 min above 80 % |
| Disk | real free space on the startup volume | `statfs("/")`: `f_bavail × f_bsize` | below 30 GB (owner: red when close to 30 GB) |
| Processes | the user's processes against the per-user limit | `proc_listpids(PROC_RUID_ONLY, getuid())`; limit the smaller of the `getrlimit(RLIMIT_NPROC)` soft limit and `kern.maxprocperuid`, a soft limit of 0 or unlimited deferring to the latter | above 80 % of the limit |

- **Memory level** (owner, 2026-11-24): the app reads `kern.memorystatus_vm_pressure_level` at
  launch, after each wake, whenever the dispatch source fires, and on the 60 s tick, and the
  value read decides the level; the event's own bits are not used. The source reports changes
  only (a test on 2026-11-24 got no event on activation), the kernel delays and smooths its
  events, and one event can carry several level bits. The sysctl is not in the SDK; the kernel
  (xnu `kern_memorystatus_notify.c`) reports it on the dispatch scale, 1 normal, 2 warning
  (which includes the kernel's "urgent"), 4 critical. It is read in one function; any other value
  leaves the card on "Not known yet".
- **Memory, yellow:** shown on the card as Apple's middle state, never red and never a message:
  Apple's guide says yellow means the Mac "might eventually need more RAM", red that it "needs
  more RAM". Warning and critical match Activity Monitor's yellow and red: under
  `memory_pressure -S` on macOS 27.2.1 (26B131), 2026-11-25, the sysctl read 2 while the graph
  was yellow and 4 while it was red.
- **Disk** (owner, 2026-11-24): real free space, matching `df` and `diskutil`, not Apple's
  "important usage" figure, which counts purgeable caches and snapshots (169 GB against 70 GB on
  one Mac) and costs 6 to 37 ms of CPU a read. The card can go red while macOS could still purge
  space; that is accepted, since a build writing to the disk sees the real free space.
- **CPU average:** the counters are machine-wide totals over all cores, 32-bit, and wrap after
  weeks of uptime (about 41 days on 12 cores), so each field's delta is `new &- old` on `UInt32`.
  Each sample stores a monotonic timestamp (`ContinuousClock`). The average uses the newest sample
  at least one window old and divides by the ticks elapsed between the two samples, which track the
  real span, so a late or skipped timer fire doesn't skew it. The ring holds 17 samples, enough for
  the longest window even when every fire is up to its 10 s tolerance late (16 gaps span at least
  950 s), so a window change applies at once.
- **CPU before the window fills:** "Not known yet" until two samples exist, then "avg N min" with
  the real span, never red until the span covers the whole window. After a wake the samples are
  dropped, and with them any CPU message.
- **CPU window:** 3 to 15 min, default 5. Below 3 a single burst could fill the average, which
  the owner ruled out ("spikes are completely fine").
- **One busy core isn't red** (this design's call): on a 12-core Mac one pegged core is about 8 %
  of the whole machine, and the owner's concern is the whole system being busy.
- **Hysteresis** for the polled metrics: CPU, disk and processes turn red past their threshold
  and clear only once back past it by a margin (5 CPU points, 2 GB, 5 % of the limit), so a value
  sitting at the line doesn't flicker. Changing a metric's own threshold drops its red first, so
  the new line is judged at once. Memory and thermal follow the kernel's own levels.
- **Thermal state:** not a card. `ProcessInfo.processInfo.thermalState` is read at launch and
  after wake, before registering for `thermalStateDidChangeNotification` (the header requires the
  property to be read first, and posts the notification on a global queue, so the handler hops to
  the main actor). `.serious` shows "Mac is running hot", `.critical` "Mac is slowing down from
  heat", with no culprit. This design's call: it costs nothing and explains slowness the four cards
  can't.

### Culprit

Found when a message appears or the panel opens while one is shown, never on the idle tick, and
once per panel opening.

- **Only the user's own processes can be read:** `proc_pid_rusage` on root's and other users'
  processes (`kernel_task`, `WindowServer`, `mds_stores`) fails with `EPERM`. The line says so:
  "Top of your processes: …".
- **Memory:** the process with the largest `ri_phys_footprint` (`proc_pid_rusage`), the figure
  `top` shows as MEM, with its size.
- **CPU:** two readings of each process's CPU time about 2 s apart; the largest delta. The times
  are Mach absolute units, converted with `mach_timebase_info`. Shown as a share of one core, as
  Activity Monitor shows it, so "340 %" can sit next to the card's whole-machine figure and the
  user finds the same number there. If the user's processes account for under half of the
  machine's busy ticks over those 2 s, the line says "Mostly system processes" instead.
- **Processes:** the executable name with the most instances ("node × 312").
- **Ties** go to the first name in sort order, so repeated scans show the same process.
- **Names** come from the last component of `proc_pidpath`, not `proc_name`, which cuts names at
  32 characters.
- **Disk:** no culprit and no button; the message says how much is free. macOS documents no way
  to open Storage settings.

### Settings

The System health pane holds every threshold (owner), each with a range, clamped when read from
`UserDefaults` as prince-sleepless does: the memory level for red (critical, or warning for a
stricter user), CPU 50 to 100 % and its window (3 to 15 min), free disk 5 to 500 GB, the process
share 50 to 95 %. A change is evaluated at once, not at the next tick.

## Efficiency

Owner's requirement: no idle CPU, few idle wakeups, low RAM, no leaks.

- **Event-driven first.** Memory pressure and thermal state arrive as system events. Sleep and
  wake come from IOKit's `IORegisterForSystemPower`, not `NSWorkspace` (its observers drew AppKit's
  power-queue deliveries, extra wakeups while idle); sleep pauses the timer, wake takes every
  reading at once and re-arms it.
- **At launch and wake,** every card is read once at once, then the timer is armed.
- **One timer for the rest:** every 60 s with about 10 s tolerance, so the system can coalesce it,
  reading the CPU counters, the process count, the disk free space, swap and the memory-pressure
  sysctl. Each read is a syscall or two; the reviewers measured `statfs` at 0.004 to 0.012 ms. No
  other timer while the panel is closed.
- **No App Nap assertion:** a late sample is harmless once samples carry their timestamp.
  (prince-clockin holds App Nap off while its timer waits; copied here, with a timer always armed,
  that would hold it off for life.)
- **While the panel is open:** a 2 s timer (tolerance at least 0.2 s) re-reads process count, disk,
  swap and memory pressure for the cards, and the panel takes the same reading as it opens. It
  never writes the CPU ring, and scans processes only when a message appears or the panel opens
  on one (see Culprit); it stops when the panel closes.
- **No subprocesses**, no polling of other apps, and no per-process scan on a tick that shows no new
  message.
- **The Metal timer:** once SwiftUI has drawn, the GPU driver wakes the app every 3 s for life,
  measured in prince-clockin and seen in Siri and other system apps too. This design accepts it, as
  prince-clockin did, and the budget below holds it to that.

### Budgets, measured before each release

Measured by the maintainer at the keyboard, since `powermetrics` needs root:
`sudo powermetrics --samplers tasks --show-process-energy -i 60000 -n 10`, the app launched with
`open -g` and given 20 s to settle first, as prince-clockin was measured.

| Measure | Budget |
|---|---|
| CPU, panel never opened | under 0.05 ms/s |
| Interrupt wakeups (`powermetrics` Intr), panel never opened | about 1 a minute (prince-clockin: 0.4) |
| Interrupt wakeups, 10 min after the panel was opened once and closed | the Metal timer's ~20 a minute plus 1 |
| Memory footprint (`footprint`, `top` MEM) after 20 panel openings | under 51 MB (prince-clockin's, measured 2026-11-24), and within about 1 MB of the figure after 5 openings |
| Leaks after 50 panel open/close cycles | none, by `leaks <pid>` on a Debug build |

A measurement past its budget blocks the release.

Idle wakeups on macOS 27.2.1, 2026-11-25: 1.5 a minute by this method and 1.22 over the next 30
minutes, which the owner counts as within "about 1". `powermetrics` reads Intr to 0.01 a second,
so the 60 s tick alone shows as 1.2 a minute.

## Testing

- **`SystemHealth` unit tests** with fake readings: the CPU average across a counter wrap, with
  uneven sample spacing, before the window fills, after wake and after a window change; the
  hysteresis margins for CPU, disk and processes; the sysctl's known and unknown values; Settings
  clamping; the message order; a message clearing when its cause ends; the Mach-time conversion for
  the culprit.
- **Manual checks on a real Mac:**
  - Memory handling with `sudo memory_pressure -S -l warn` and `-l critical` (simulated; it
    needs root). The simulated level moves Activity Monitor's graph too, so the real
    `memory_pressure -l`, which allocates memory and can make the system kill idle processes, is
    not needed.
  - CPU held high by a busy loop for longer than the window, and a short spike that must not turn
    red.
  - Disk and process thresholds set past the current value; Activity Monitor opening from the
    button; VoiceOver reading each card; the budgets above.

## Left to the builder

- The SF Symbols for each state and the card layout's exact sizes, in the Prince popover look.
- How the culprit's percentage and size are rounded and worded.
