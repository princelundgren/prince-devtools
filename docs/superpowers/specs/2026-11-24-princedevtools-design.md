---
status: building
verified: 2026-11-27
governs:
  - PrinceDevTools/**
  - PrinceDevToolsCore/**
  - .github/workflows/release.yml
  - .github/workflows/ci.yml
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
- **System health:** memory pressure, CPU averaged over minutes for the whole Mac and each of the
  user's processes minute by minute, free disk space, and process count against the macOS limit,
  each against a threshold the user can change.
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
- Stopping or killing processes from the panel (owner): Activity Monitor does that. The server
  list is the one exception (owner, 2026-11-27), since Activity Monitor can't be opened with a
  process selected: see `2026-11-26-localhost-servers-design.md`.
- Grouping an agent with its helper processes; the culprit is one process by name.
- Typed or pasted tools (JSON, Base64, JWT): they belong in a web tool, not a menu bar panel
  (owner).
- The later tools; the shell only has to make adding one a new card, message source, Settings pane
  and module, and for a tool with a list, the panel's second view.
- Watching other users' processes: the process meter counts the current user's, which is the
  limit their agents hit.

## Anti-goals

- **A monitor that costs what it monitors**: any idle CPU, a wakeup rate above the budget, RAM that
  grows over time.
- **Crying wolf**: red on a CPU spike well under a minute, on Apple's yellow memory pressure, on a
  partial CPU window, or a message that flickers at a threshold.
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
  by every tool, and the Settings text for launch at login and the version), `LocalServers` (the
  localhost servers tool's list from libproc, its wording and its scans, no AppKit; its own
  design is `2026-11-26-localhost-servers-design.md`). Tests per target.
- CI, CodeQL, the Claude review workflow, Dependabot and `release.yml` adapted from
  prince-clockin. CI and the release's test job run on the maintainer's self-hosted pool
  `prince-devtools-macos`, a fresh macOS VM per job, as prince-clockin's do (owner,
  2026-11-27): GitHub's Free plan runs 5 macOS jobs at a time for an account, and jobs waited up to
  42 minutes for one. A fork's pull request runs on GitHub's `xcode-27`, since the pool refuses
  its job. The release's other jobs and CodeQL stay on GitHub-hosted runners.
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
│ ▲ CPU avg 1 min is 91 %              │
│   Top of your processes: node 340 %  │
│              [Open Activity Monitor] │
├──────────────────────────────────────┤
│ ┌─ Memory ─────────┐ ┌─ CPU ───────┐ │
│ │ ▲ Red            │ │ ▲ 91 %      │ │
│ │ Swap 8.3 GB      │ │ avg 1 min   │ │
│ └──────────────────┘ └─────────────┘ │
│ ┌─ Disk ───────────┐ ┌─ Processes ─┐ │
│ │ ● 70 GB free     │ │ ● 755/4000  │ │
│ │                  │ │ ▬▬▬───────  │ │
│ └──────────────────┘ └─────────────┘ │
│ ┌─ Servers ────────┐                 │
│ │ ⓘ 3 listening    │                 │
│ │ 1 orphaned       │                 │
│ └──────────────────┘                 │
├──────────────────────────────────────┤
│ ⚙                                  ⏻ │
└──────────────────────────────────────┘
```

- **Message area at the top** (owner chose top or bottom; top is this design's call: the problem
  is the first thing seen). One message per cause, in a fixed order: memory, disk, processes, CPU,
  a busy process, thermal; later tools' messages follow in panel order. A fixed order needs no
  severity model and keeps the area from reshuffling. **One Open Activity Monitor button** at the
  foot of the area, shown while any memory, CPU, busy-process, process or thermal message is
  present. A message disappears when its cause ends.
- **Message wording** for the lines the mockup doesn't show: disk "28 GB free on the startup
  disk", processes "3,300 of 4,000 processes in use", a busy process "node has used 98 % of a
  core for 1 min" (it names the process, so it needs no culprit line). A busy process and the
  whole-machine average are separate causes, so both messages can show, the whole machine first.
  When a busy process turns the CPU card red, the card keeps the whole-machine average as its
  value and names the process on its second line, "node at 98 % of a core", in place of the
  window (owner, 2026-11-26), so the card and its VoiceOver label say why it is red.
- **Cards** in a two-column grid, all the same size: each as tall as the tallest, its lines at the
  top (owner, 2026-11-26). Each has a title, a status symbol and one or two lines. States:
  green, red, memory's yellow, **informational** (blue, neither green nor red: a card that
  reports without judging) and **"Not known yet"** (neutral, never green or red) until a card
  has its first reading. Each state has its own symbol, never colour alone; colours use
  prince-clockin's tokens with their Increase Contrast variants. Each card is one VoiceOver
  element naming its value and state. A card that opens something on a click is a button,
  looking as the others do, whose VoiceOver hint says what the click does.
- **A card that opens a list** (the Servers card, `2026-11-26-localhost-servers-design.md`): a
  click shows the panel's second view, the list in place of the messages and cards, under a header
  with Back and the tool's title. The footer stays; the panel widens for the list, narrows again
  on Back, and opens on the cards each time.
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
| CPU | average CPU % over the window, all cores; and each of the user's processes as a share of one core | cumulative ticks from `host_statistics(HOST_CPU_LOAD_INFO)`; each process's `ri_user_time + ri_system_time` from `proc_pid_rusage` | average over 1 min above 80 %, or one of the user's processes above 90 % of a core in every minute of the window |
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
  at least one window old, less the tick's 10 s tolerance, and divides by the ticks elapsed between
  the two samples, which track the real span, so a late or skipped timer fire doesn't skew it. The
  10 s of slack is there because a repeating timer keeps its schedule: a fire up to 10 s late is
  followed by a gap up to 10 s short, which still counts as a whole minute. The ring holds 17
  samples, so a window change applies at once: with the slack, 15 gaps fill the longest window,
  and the 16th covers a fire or scan more than 10 s late.
- **CPU before the window fills:** "Not known yet" until two samples exist, then "avg N min" with
  the real span, never red until the span covers the whole window, less the slack. After a wake
  the samples are dropped, and with them any CPU message.
- **CPU window:** 1 to 15 min, default 1 (owner, 2026-11-26), for a figure that follows the
  Mac closely. One minute is the 60 s tick's shortest window. A burst that holds the average over
  the threshold for a tick's gap can turn the card red, and each time the CPU message appears the
  culprit search runs, so a build alternating busy and quiet minutes can run it each minute. A busy
  process turns the card red about two to three minutes after it starts on an otherwise idle Mac,
  sooner on a busy one: a busy minute opens its
  scan, the first scan is only a baseline, and the next tick's interval fills the window.
- **One busy process** (owner, 2026-11-26): the whole-machine average can't see a runaway
  process, since one pegged core is about 8 % of a 12-core Mac. So the CPU card also turns red when
  one of the user's processes uses more than 90 % of a core in every minute of the CPU window.
  - **Per minute, not averaged:** each 60 s tick compares each process's CPU time with the
    previous tick's, over the measured span (`ContinuousClock`). Red once a run of minutes in a
    row over the threshold spans the window, less the same 10 s of slack; a quieter minute starts
    the run over, so a burst never adds up to red.
  - **Clearing:** red until a minute falls 5 points below the threshold (85 % by default), the
    process exits, or sleep or wake drops what is kept. A pid whose CPU time fell is a reused pid
    and starts over.
  - **The busiest one:** the message names the process with the highest share in the last minute;
    ties go to the first name in sort order.
  - **Scanned only when it can matter:** the tick already has the machine's busy ticks for the
    last minute. Below the clearing share of one core no process can be at it, so the tick skips
    the scan and drops what is kept. An idle Mac never scans. A raised threshold raises the gate
    too, so the minutes it drops are gone if the threshold is lowered again.
  - **The user's processes only,** as `proc_listpids(PROC_RUID_ONLY, getuid())`, since
    `proc_pid_rusage` can't read root's. The scan reads only CPU time; a name is read with
    `proc_pidpath` only for a process that is red. CPU time is in Mach absolute units, converted
    with `mach_timebase_info` as for the culprit. A scan no later than the last one recorded is
    ignored, so a scan delayed past the next tick can't count a minute twice. Kept: each pid's CPU
    time at the last scan, and each process's last 16 minutes, so a changed threshold is judged at
    once against them; the 16th covers a scan delayed more than 10 s, since the scan is a
    background task. A minute below 45 %, the clearing share of the lowest threshold Settings
    allows, forgets the process.
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
once per panel opening. Until it is found, the message shows without its culprit line.

- **Only the user's own processes can be read:** `proc_pid_rusage` on root's and other users'
  processes (`kernel_task`, `WindowServer`, `mds_stores`) fails with `EPERM`. The line says so:
  "Top of your processes: …".
- **Memory:** the process with the largest `ri_phys_footprint` (`proc_pid_rusage`), the figure
  `top` shows as MEM, with its size.
- **CPU:** two readings of each process's CPU time about 2 s apart; the largest delta, over the
  span measured between them. The times
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
stricter user), CPU 50 to 100 % and its window (1 to 15 min), one process's share of a core 50 to
400 % (default 90 %), free disk 5 to 500 GB, the process share 50 to 95 %. A change is evaluated
at once, not at the next tick; a new per-process threshold applies to the minutes already kept.

## Efficiency

Owner's requirement: no idle CPU, few idle wakeups, low RAM, no leaks.

- **Event-driven first.** Memory pressure and thermal state arrive as system events. Sleep and
  wake come from IOKit's `IORegisterForSystemPower`, not `NSWorkspace` (its observers drew AppKit's
  power-queue deliveries, extra wakeups while idle); sleep pauses the timer, wake takes every
  reading at once and re-arms it.
- **At launch and wake,** every card is read once at once, then the timer is armed.
- **One timer for the rest:** every 60 s with about 10 s tolerance, so the system can coalesce it,
  reading the CPU counters, the process count, the disk free space, swap and the memory-pressure
  sysctl. Each read is a syscall or two, apart from the busy-process scan below; the reviewers
  measured `statfs` at 0.004 to 0.012 ms. No other timer while the panel is closed.
- **No App Nap assertion:** a late sample is harmless once samples carry their timestamp.
  (prince-clockin holds App Nap off while its timer waits; copied here, with a timer always armed,
  that would hold it off for life.)
- **While the panel is open:** a 2 s timer (tolerance at least 0.2 s) re-reads process count, disk,
  swap and memory pressure for the cards, and the panel takes the same reading as it opens. It
  never writes the CPU ring, and scans processes only when a message appears or the panel opens
  on one (see Culprit); it stops when the panel closes. The 60 s tick, and its busy-process scan,
  keep running beside it. The servers tool scans once as the panel opens and every 2 s while its
  list is shown (`2026-11-26-localhost-servers-design.md`, "When it scans").
- **No subprocesses**, no polling of other apps, and no per-process scan while the panel is closed
  except the busy-process one, which the tick runs only while the machine is busy enough for a
  process to be at its clearing share (see "One busy process"). A scan of the user's 890
  processes' CPU time measured 0.8 to 1.0 ms of CPU on a 12-core Mac, 2026-11-26, about 0.017 ms/s
  at one a minute; reading every path as well took 2.3 to 3.8 ms, which would break the CPU budget
  below on a busy Mac.
- **Low priority** (owner, 2026-11-26): every process scan, the busy-process one and the
  culprit's, runs as a `.background` priority task, so the system schedules it behind other apps'
  work and lowers its CPU and I/O priority. The result is applied when it arrives; nothing in the
  app awaits it, since awaiting would raise its priority to the waiter's.
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
| CPU, panel never opened, one `yes > /dev/null` running throughout | under 0.05 ms/s |
| Interrupt wakeups (`powermetrics` Intr), panel never opened | about 1 a minute (prince-clockin: 0.4) |
| Interrupt wakeups, 10 min after the panel was opened once and closed | the Metal timer's ~20 a minute plus 1 |
| Memory footprint (`footprint`, `top` MEM) after 20 panel openings | under 51 MB (prince-clockin's, measured 2026-11-24), and within about 1 MB of the figure after 5 openings |
| Leaks after 50 panel open/close cycles | none, by `leaks <pid>` on a Debug build |

A measurement past its budget blocks the release.

Idle CPU, panel never opened, Release build, 2026-11-25, before the busy-process scan existed: 0.013 ms/s on average over ten 60 s
samples (0.01 to 0.02 each).

Idle wakeups on macOS 27.2.1, 2026-11-25: 1.5 a minute by this method and 1.22 over the next 30
minutes, which the owner counts as within "about 1". `powermetrics` reads Intr to 0.01 a second,
so the 60 s tick alone shows as 1.2 a minute.

## Testing

- **`SystemHealth` unit tests** with fake readings: the CPU average across a counter wrap, with
  uneven sample spacing, before the window fills, a span up to 10 s short of it, after wake and
  after a window change; the
  hysteresis margins for CPU, disk and processes; the sysctl's known and unknown values; Settings
  clamping; the message order; a message clearing when its cause ends; the Mach-time conversion for
  the culprit; a busy process turning red only after a full window of minutes over the threshold,
  a quieter minute resetting it, its clearing margin, a reused pid, the scan skipped below the gate,
  a name read only for a red process, the Mach-time conversion for it, a scan older than the last
  one ignored.
- **Manual checks on a real Mac:**
  - Memory handling with `sudo memory_pressure -S -l warn` and `-l critical` (simulated; it
    needs root). The simulated level moves Activity Monitor's graph too, so the real
    `memory_pressure -l`, which allocates memory and can make the system kill idle processes, is
    not needed.
  - CPU held high by a busy loop for longer than the window, and a short spike that must not turn
    red; one single-threaded loop (`yes > /dev/null`) longer than the window turning the card red
    with its name while the whole-machine average stays low.
  - Disk and process thresholds set past the current value; Activity Monitor opening from the
    button; VoiceOver reading each card; the budgets above.

## Left to the builder

- The SF Symbols for each state and the card layout's exact sizes, in the Prince popover look.
- How the culprit's percentage and size are rounded and worded.
