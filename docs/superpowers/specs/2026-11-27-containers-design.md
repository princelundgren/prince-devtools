---
status: building
verified: 2026-11-27
governs:
  - PrinceDevToolsCore/Sources/Containers/**
  - PrinceDevToolsCore/Tests/ContainersTests/**
  - PrinceDevTools/PrinceDevTools/Container*.swift
---

# PrinceDevTools: containers

PrinceDevTools' third tool: the containers running on the Mac, across container runtimes, with
how much memory each uses. The app's design (`2026-11-24-princedevtools-design.md`) covers the
shell; the localhost servers design (`2026-11-26-localhost-servers-design.md`) set the pattern of
a card that opens a list, which this tool follows.

## Why

The owner wants to find out whether any containers are running, how many, and how much RAM they
use. Like the servers, it is looked up, not an alarm.

## Goals

- **A Containers card** in the panel's grid: how many containers run and the memory they use
  together. A click on it shows the list.
- **A row per running container:** name, image, runtime, time up and memory.
- **Every Docker-compatible runtime the Mac runs:** OrbStack, Docker Desktop, Podman, Colima and
  Rancher Desktop, which all serve the Docker Engine API on a Unix socket.
- **Never starts or wakes a runtime,** and reads nothing while the panel is closed.

## Non-goals

- **The memory a runtime takes from the Mac** (its virtual machine's footprint): the owner chose
  each container's own memory, 2026-11-27, the figure `docker stats` shows.
- **Stopped containers:** the question is what is running (this design's call).
- **Acting on a container** (stop, restart, logs, a shell): OrbStack's menu bar and Docker
  Desktop's dashboard do that for their own runtimes (this design's call).
- **Apple's `container`** (owner, 2026-11-27): it has no Docker socket, and reading it takes
  Apple's `ContainerAPIClient` package, which the app's rule of no runtime dependency but Sparkle
  keeps out. It comes back if the owner starts using `container` and decides the dependency is worth
  it; a client of our own for its XPC service was turned down, since its message format is private.
- CPU, network and disk use; Kubernetes pods; OrbStack's Linux machines.
- **Remote Docker endpoints** (a context over `tcp://` or `ssh://`): only Unix sockets on this Mac.
- Alerts, and a Settings pane.

## Anti-goals

- Starting or waking a runtime to answer the card.
- Running `docker` or `podman`: the app runs no subprocess (`AGENTS.md`).

## Approaches

1. **The runtimes' own views.** OrbStack's menu bar lists and manages its containers
   (docs.orbstack.dev/menu-bar); Docker Desktop's Containers view has columns for memory use
   (docs.docker.com/desktop/use-desktop/container). Each shows only its own runtime. Not adopted.
2. **Podman Desktop,** which shows the containers of several engines (Podman, Docker, Lima) in one
   dashboard (its README, "Multiple container engine support"). It is a separate app with a window
   of its own, not a glance in this panel beside the servers. Not adopted.
3. **Read the Docker Engine API from the app,** over each runtime's Unix socket. **Chosen** (owner,
   2026-11-27). Running the command-line tools instead is ruled out by the no-subprocess rule.

## Which runtimes

At each scan the app looks for these Docker Engine API sockets, in this order:

| Runtime | Socket |
|---|---|
| OrbStack | `~/.orbstack/run/docker.sock` |
| Docker Desktop | `~/.docker/run/docker.sock` |
| Rancher Desktop | `~/.rd/docker.sock` |
| Colima | `~/.colima/<profile>/docker.sock`, each profile |
| Podman | `$TMPDIR/podman/<machine>-api.sock`, each machine |

- **The active Docker context** also counts: `currentContext` in `~/.docker/config.json`, whose
  endpoint is `Endpoints.docker.Host` in `~/.docker/contexts/meta/<SHA-256 of its name>/meta.json`.
  Only a `unix://` host with an absolute path. A missing or unreadable file means no context.
- **`/var/run/docker.sock`** counts too, since Docker Desktop and OrbStack can link it to their own.
- **Names from the disk** (Colima profiles, Podman machines, the context) have each control,
  bidi-control, line-separator or paragraph-separator character replaced by U+FFFD and are cut
  to 1,024 bytes, so a name can't move or hide text in the panel (this design's call).
- **Only the user's own sockets:** a socket is read only if the user owns both its resolved file
  and the folder that holds it (this design's call). On a shared Mac, `/var/run/docker.sock` can
  link into another account's folder, where that account can swap the file, or hard-link the
  user's own socket there and then swap it, to answer the app's requests. Every socket in the
  table is under the user's home or `$TMPDIR`.
- **One runtime per engine:** symlinks are resolved first, then each socket's `GET /info` `ID`
  ("unique identifier of the daemon", per the Engine API) is compared, so an engine served at two
  socket files counts once (this design's call): each is read, and the second is dropped. Only two
  separate socket files, not a symlink, are read twice. An empty `ID` matches no other. A socket
  from the table keeps that table's name; any other is named after its context, or "Docker".
  Podman's `/info` gives a new `ID` on each call, so a Podman engine is matched by its resolved
  socket path alone. A socket that fails has no `ID` to compare, so it shows as unreadable even
  when another socket read its engine (this design's call).
- **`DOCKER_HOST` is ignored:** an app started from the Finder doesn't get the shell's environment
  (this design's call).
- **Not running:** a socket file that is missing, isn't a socket, or refuses the connection, is a
  runtime that's stopped. It is left out, with no error.
- **Can't read:** a socket that accepts the connection but whose reads fail (a timeout, an error
  status, a response the app can't decode) is a runtime that runs and can't be read. It is never
  left out silently, since "None running" while containers run is the one wrong answer this tool
  must not give (see "The card").

## Reading

- **The connection:** HTTP/1.1 over the Unix socket with Network.framework (`NWConnection` to
  `NWEndpoint.unix(path:)`), since `URLSession` doesn't connect to Unix sockets. No new dependency.
  - `GET /version` first, on each read of a socket, for `ApiVersion`; then the requests use that
    version in their paths, never a pinned one.
  - `GET /containers/json` lists the running containers: `Id`, `Names`, `Image`, `Created`.
    Without `all=true`, so only running ones.
  - `GET /containers/{id}/stats?stream=false&one-shot=true` for each running container: its memory
    in use is `memory_stats.usage` less its inactive file cache, as `docker stats` figures it: less
    `stats.total_inactive_file` on cgroups v1, else less `stats.inactive_file` (v2), each only
    while below `usage`. `one-shot` skips the two-sample wait, which only CPU needs. At most 16 are
    in flight per engine.
  - Time up: from `Created`, since the list's `Status` text is for people, not parsing (this
    design's call; a restarted container then counts from its creation).
- **Failures:** a runtime whose reads fail midway is one the app can't read, for that scan; a
  container whose stats fail, or whose memory figure is above `Int64.max`, shows "—" for memory
  and is not counted in the card's total.
- **More than 500 containers** from one engine make it a runtime the app can't read, never a
  shortened list (this design's call): the cap bounds how long a scan reads and how many rows the
  list holds.
- **Values from the engine are checked** before they go into a request: an `ApiVersion` that
  isn't `<digits>.<digits>` makes the runtime unreadable, and a container `Id` outside
  `[0-9A-Za-z][0-9A-Za-z_.-]*` (so never `..`) gets no stats request and shows "—". Names and
  images are cleaned as the runtime names from the disk are ("Which runtimes").
- **Response limits:** 16 MiB for the container list, 64 KiB for each container's stats (a
  recorded one-shot stats body is 1,768 bytes) and 1 MiB for every other response; a larger
  response is a failed read.
- **Timeouts:** each request has a short timeout of the builder's choosing, so a hung runtime
  never holds up the scan.

## The card

- Title "Containers". Value "3 running", "1 running" or "None running"; detail is the total
  memory, formatted for memory and the locale (`1.2 GB`), when any are running. "Not known yet"
  until the first scan. The informational tone, as Servers.
- **A runtime the app can't read** adds to the detail: "1.2 GB, 1 runtime unreadable". With none
  read at all and one unreadable, the value is "Can't read" (this design's calls).
- It is always in the grid, whether or not a runtime is installed (this design's call): the sixth
  card fills the third row.
- A click on it, or activating it with VoiceOver, shows the list.

## The list

- **The panel's second view,** as Servers': a header with Back and the title "Containers", the
  table, and the footer.
- **Columns:** Name, Image, Runtime, Up, Memory. Sorted by memory, largest first (this design's
  call: the question is where the RAM goes).
- **A click on the name or image copies it,** with the "Copied" confirmation, as Servers' cells.
  No row menu.
- **Empty:** "No containers running", unless no runtime was read and one couldn't be; then only
  the lines naming the runtimes it couldn't read, as the card says "Can't read".
- **Each runtime the app can't read** gets a line under the table naming it: "Couldn't read Podman".

## When it scans

As the servers: one scan when the panel opens, for the card; every 2 s while the list is shown;
nothing while the panel is closed. Each scan runs at background priority, and a result older than
the one applied is dropped. The runtimes are read in parallel.

## Shell changes

- `PrinceDevToolsCore/Package.swift` gains a `Containers` library and its tests;
  `PrinceDevTools/project.yml` its product. No new dependency.
- The app's design gains the card, its target list and its "adding a tool" lines, in the commits
  that build them.

## Testing

- **Unit tests** with recorded API responses: the socket list (a symlink to a known socket read
  once, two sockets with one engine `ID` as one, a context socket, a `tcp://` context skipped),
  a refused socket left out and a failing one shown as unreadable on the card and the list, the
  memory figure on cgroups v1 and v2, failed stats shown as "—" and left out of the total, a
  runtime failing midway, the card's wording for 0, 1 and many, the sort by memory, and a stale
  scan dropped.
- **On a real Mac:** with OrbStack running and `docker run -d nginx`, the card and row show it
  within one scan, and its memory is within a few percent of `docker stats --no-stream`; with
  OrbStack stopped, the card says "None running" and OrbStack stays stopped; two runtimes running
  at once both list.

## Unverified

- **Docker Desktop's Resource Saver:** it stops Docker Desktop's VM when no container has run for
  a while, and its docs say listing commands "don't necessarily" wake it. The build checks that
  opening the panel leaves the moon icon in place. If a list wakes it, that goes back to the owner
  before the build goes on.
- **The other runtimes:** whether connecting to a stopped Colima's, Podman's or Rancher Desktop's
  socket can start it. For OrbStack, its FAQ says a client that
  connects while it is stopped gets "Cannot connect to the Docker daemon", so a read doesn't.
  The build checks each runtime it can install the same way; one that wakes goes back to the owner.

## Left to the builder

- The HTTP reader's shape and the request timeout.
- The SF Symbol, the column widths and how the time up is worded (as Servers': "10 h", "3 d").
