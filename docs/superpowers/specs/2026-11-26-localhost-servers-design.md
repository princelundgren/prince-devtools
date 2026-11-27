---
status: building
verified: 2026-11-27
governs:
  - PrinceDevToolsCore/Sources/LocalServers/**
  - PrinceDevToolsCore/Tests/LocalServersTests/**
  - PrinceDevTools/PrinceDevTools/Server*.swift
---

# PrinceDevTools: localhost servers

PrinceDevTools' second tool: the dev servers listening on the Mac, each with its port, its
process, its folder and how long it has run. The app's own design
(`2026-11-24-princedevtools-design.md`) covers the shell and system health; this one covers the
tool.

## Why

Coding agents start dev servers and leave them running (owner). The user wants to find them and
see, for each, which port and which process, enough to tell whether it is still needed. It is
looked up, not an alarm.

## Goals

- **A Servers card** in the panel's grid: how many servers listen, and how many have lost the
  process that started them. A click on it shows the list (owner chose a card that opens a list,
  for a glance first and the detail a click away).
- **A row per server:** port, process name, pid, folder, time running, and a mark when its parent
  process is gone. Its menu opens `http://localhost:<port>` in the default browser.
- **Only the servers someone started** (owner chose the fixed-ports and home-folder filters): see
  "Which listeners show".
- As cheap as the rest of the app: no scan while the panel is closed.

## Non-goals

- **Alerts:** no message, no red or yellow card, no change to the menu bar icon. A running server
  is not a fault (this design's call).
- Linking a server to the agent session that started it, its git branch, or its memory and CPU.
- Other users' and root's servers: macOS lets an app without privileges read only its own user's
  processes (`proc_pidinfo` fails with `EPERM` on the others, checked on a 12-core Mac on macOS 27,
  2026-11-26).
- UDP, and Unix-domain sockets.
- **Servers outside the home folder:** `brew services` (postgresql and nginx run in
  `/opt/homebrew`, redis in `/opt/homebrew/var`, per `brew info --json=v2`), apps `launchd` starts
  in `/`, and a server started from `/tmp` are hidden by the folder filter, by design. Containers
  are not this tool's subject.
- A Settings pane: there is nothing to set.

## Anti-goals

- A list that buries the leftover servers under app internals (a probe showed 34 listening
  processes on one Mac, most of them apps' own sockets).
- Any CPU or wakeups while the panel is closed.

## Approaches

1. **A `LocalServers` library target in `PrinceDevToolsCore`, read through libproc.**
   **Chosen** (owner, 2026-11-26). Fits the app's rules: no subprocess, no entitlement, one app.
2. **Adopt WhatThePort** (`tomjohndesign/what-the-port`, MIT, Swift, active), and drop the tool.
   It already does this and more (the agent session behind a server, its branch, leak warnings,
   stopping), but it is a second menu bar app, which PrinceDevTools exists to replace, and it runs
   `/usr/sbin/lsof` and notifies, both against this app's rules. Rejected. Its
   code may be read for reference, with credit for anything taken. manfath (`Dnymte/manfath`, MIT)
   is the same shape, also on `lsof`.
3. **Port WhatThePort's code:** its core parses `lsof` output, which the no-subprocess rule
   discards, so little would carry over. Rejected.

## Which listeners show

A **server** is a TCP socket in the `LISTEN` state held by one of the user's processes, when both
hold:

- **Its port is below 49152.** Ports the kernel hands out for a bind to port 0 come from
  `net.inet.ip.portrange.first` to `.last`, 49152 to 65535 by default; dev servers bind fixed
  ports (3000, 5173, 8000). This drops apps' internal sockets, such as each Claude Code session's
  local port. The bound is read from `net.inet.ip.portrange.first` at each scan (this design's
  call: a user who changed it keeps the filter right); a failed read uses 49152.
- **Its process's working directory is the user's home folder or below it** (owner, 2026-11-26),
  compared by whole path components, so a sibling folder whose name only starts with the home
  folder's is not under it. A server started from a shell or by an agent runs in its project; apps
  `launchd` starts run in `/`, and `brew services` in `/opt/homebrew/…`. The test is on the path the
  kernel reports, so a deleted folder under the home folder still passes; a folder that can't be
  read at all passes too, since it may be a deleted one (see "Reading").

**One row per listening socket**, keyed on the socket's kernel handle (`soi_so`): forked workers
that inherit one socket (gunicorn, uvicorn `--reload`, node `cluster`) are one row, shown as the
oldest process holding it (earliest start, then lowest pid). One process listening on the same
port over IPv4 and IPv6 holds two sockets and is one row too: rows merge on process and port after
the socket merge. One process on two ports is two rows (this design's calls).

## Reading

Through `<libproc.h>` and `<sys/proc_info.h>`, on the user's processes from
`proc_listpids(PROC_RUID_ONLY, getuid())`, as system health does, plus one `sysctlbyname` (the
port floor) and one `lstat` per server (folder gone). No subprocess, no entitlement.

- **Sockets:** `proc_pidinfo(PROC_PIDLISTFDS)` for each process's descriptors; for each of type
  `PROX_FDTYPE_SOCKET`, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. A server is one with `soi_kind ==
  SOCKINFO_TCP` and `tcpsi_state == TSI_S_LISTEN`; its port is `insi_lport` in network byte order.
  Its address is read by `soi_family`: `insi_laddr.ina_6` for `AF_INET6`, `ina_46.i46a_addr4` for
  `AF_INET`. Not by `insi_vflag`: a dual-stack listener on `::` (node's and Python's default) has
  both its IPv4 and IPv6 bits set.
- **Name:** the last component of `proc_pidpath`, as system health's culprit.
- **Folder:** `proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `pvi_cdir.vip_path` and its inode and device
  (`pvi_cdir.vip_vi.vi_stat`). A deleted folder shows two ways, both seen on macOS 27, 2026-11-26:
  the read fails with `ENOENT` (older leftovers, which `lsof` can't read either), or it still
  returns the old path (a folder deleted seconds before). So "folder gone" is a failed read, an
  empty path, or an `lstat` of the path that fails with `ENOENT` or finds another inode or device.
  - No privacy (TCC) prompt: an `lstat` of a server's folder in `~/Documents` raised none for a
    fresh, unsigned app identity (macOS 27, 2026-11-27).
- **Start time and parent:** `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_start_tvsec` and `pbi_ppid`,
  for each server's process, then up its chain only as far as the walk climbs (see "Parent gone"),
  not for every process. Each walked process's folder is read with its record, by
  `PROC_PIDVNODEPATHINFO` alone, no `lstat`; the walk uses it only when the parent is 1.
- **Failures:** a process whose sockets or start time can't be read (it exited mid-scan) is
  skipped; a failed name read shows its pid; a failed folder read is "folder gone", as above.
- **Cost:** one scan of 870 processes measured 5.6 ms on a 12-core Mac, 2026-11-26 (a probe; the
  module's own scan is measured again in the build).

## The card

- Title "Servers". Value "8 listening", "1 listening", "None listening"; detail "3 orphaned"
  when any are, none otherwise (owner chose "orphaned", 2026-11-26). The "Not known yet" state
  until the first scan, then a new informational tone, neither green nor red, with its own symbol
  (see "Shell changes").
- A click on the card, or activating it with VoiceOver, shows the list. Its VoiceOver label
  names the value and the detail and says it opens the list.

## The list

- **Replaces the cards and messages** in the panel; a header with a Back control and the title
  "Servers" returns to them. The footer stays. The panel opens on the cards each time.
- **Rows** (owner chose a table, 2026-11-26): one line per server under column titles Port,
  Process, PID, Folder, Running and Orphaned: `:8000  python3  4242  image-gen  10 h  ⚠`; the
  folder is its last component; the pid, beside the name, makes the process easy to find in
  Activity Monitor; the ⚠ symbol (with a help tag "Orphaned: the process that started it has
  exited") when its parent is gone. The panel widens for the list and narrows again on Back; the
  cards keep their width.
- **Parent gone** (owner chose the chain, 2026-11-26): agents start servers through a wrapper
  (`npm run dev`, `uv run`, a shell), and when the session ends the wrapper is handed to `launchd`
  (pid 1), not the server under it (checked on macOS 27, 2026-11-26: after the outer shell exited,
  `sh -c "python3 -m http.server …"` had parent 1 and python's parent stayed `sh`). So the walk
  starts at the row's process and climbs `pbi_ppid`:
  - the parent is 1: gone if this process's folder is inside the home folder, by the same test as
    the filter, since an app `launchd` starts (Terminal, an agent app) runs in `/` and its children
    are not orphans;
  - the parent is not one of the user's processes (`login`, `sshd`): not gone;
  - else climb to the parent. A loop or a chain over 64 long stops as not gone.
- **Order:** rows with ⚠ first, then by port, then by pid.
- **Help tag and VoiceOver label** per row: port, process, pid, the full folder with the home
  directory written `~`, the listening addresses (two for a merged IPv4 and IPv6 row), time
  running in words ("10 hours"), and "orphaned" when it applies.
- **A click on a cell** (owner chose it, 2026-11-27): the port copies `http://localhost:<port>`,
  the name and the pid copy themselves, each showing "Copied" for a moment, and the folder
  shows it in Finder (not when it is gone). The cell under the pointer is highlighted.
- **Open in Browser**, from the row's menu, opens `http://localhost:<port>` with
  `NSWorkspace.shared.open`; a server that isn't HTTP shows the browser's own error.
- **A row's menu** (owner chose it, 2026-11-26), on right-click and on a … that shows at the
  end of the row under the pointer: Open in Browser, Copy Link (`http://localhost:<port>`), Copy
  PID, Show Folder in Finder (`NSWorkspace.activateFileViewerSelecting`, off when the folder is
  gone), Stop Server… and Force Stop Server…. Activity Monitor has no URL scheme or scripting
  dictionary, and its search doesn't match a pid (owner checked, 2026-11-27), so the app can't
  open it on the process and the menu leaves it out.
- **Stopping a server** (owner, 2026-11-27, reversing the app's rule for this list, since
  Activity Monitor can't be opened on the process): Stop sends `SIGTERM`, Force Stop `SIGKILL`,
  each with `kill(2)` after a dialog naming the process, port and pid. Right before sending, the
  pid's start time must still be the scan's, since the list can be a scan old and pids are
  reused; otherwise nothing is sent and the panel says the process had already exited. A refused
  signal is reported too. The list scans again at once.
- **Empty:** "No servers listening" in place of rows.
- **Open Activity Monitor** at the list's foot, as in the message area.
- **Parent gone is a hint, not a verdict:** a process that detaches on purpose also ends its
  chain at 1 with a folder: `ssh -f`, a daemon, and a `tmux` server, so a server in a `tmux` pane
  shows ⚠ while its session lives. Accepted (owner, 2026-11-26).

## When it scans

- **On panel open:** one scan, for the card. Nothing while the panel is closed.
- **While the list is shown:** every 2 s, on a timer of the module's own with at least 0.2 s
  tolerance, armed when the list appears and stopped when it goes or the panel closes. A tick
  while a scan still runs starts none, so slow scans don't stack up.
- **Background priority:** each scan runs as a `.background` task, and its result is applied when
  it arrives, as system health's scans (the app's design, "Low priority"). A result from a scan
  older than the one applied is dropped.
- **Panel-open cost:** at 5.6 ms a scan, about 2.8 ms/s while the list is shown. The idle budgets
  in the app's design don't change: the panel-closed measures see no scan.

## Shell changes

- The panel gains a second view (the list) and a way back.
- `PanelKit`'s card becomes clickable for a card that opens something, and keeps today's look
  for those that don't; `PanelTone` gains the informational tone and its symbol.
- The fifth card makes the grid three rows; the cards keep one size.
- `PrinceDevToolsCore/Package.swift` gains the `LocalServers` library and `LocalServersTests`, and
  `PrinceDevTools/project.yml` the product.
- The app's design is updated in the commits that build these: its target list (`SystemHealth`,
  `PanelKit`), its Panel section and card states, the Efficiency lines that name the only process
  scans, and "adding a tool is a new card, message source, Settings pane and module", which this
  tool meets with a card, a second view and a module.

## Testing

- **`LocalServers` unit tests** with fake readings: the port filter at 49151 and 49152 and with a
  changed range, the home-folder filter (in it, `/`, `/opt/homebrew`, a deleted folder under it),
  folder gone by a failed read and by a changed inode, IPv4 and IPv6 on one port as one row,
  forked workers on one socket as one row showing the oldest, two ports as two rows, the sort
  order; parent gone for a direct orphan, a wrapped one, a chain ending at an app in `/`, a chain
  ending at another user's process, a loop; a process failing mid-scan skipped, a stale scan
  result dropped, the card's wording for 0, 1 and many; Stop sending its signal only while the
  start time matches, never to a pid of 0 or below, an exited process read as changed, a refused
  signal's error, and a real child process ended. `PanelKit`: the clickable card and a five-card
  `CardGrid`.
- **On a real Mac:** `python3 -m http.server 8765` in a folder shows its row within one scan; a
  click on its port copies its link, and Open in Browser in its menu opens it; the row gets ⚠ when
  the shell that started it is killed, and so does one started as
  `sh -c "python3 -m http.server 8766; :" &` from a shell that then exits; deleting its folder
  shows "folder gone"; a server on a random port (`python3 -m http.server 0`) or in `/tmp` does
  not show; a dual-stack listener shows its address; Stop and Force Stop in its menu end it after
  the confirmation, and a refusal shows its message; no privacy prompt for a server in
  `~/Documents`; VoiceOver reads the card and a row; the scan time on the Mac's real process count;
  the panel-closed budgets unchanged.

## Left to the builder

- The SF Symbols, the row layout's exact sizes, and how the time running is rounded and worded.
- The Back control's look and the transition between the two views.
