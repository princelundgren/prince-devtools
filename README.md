# PrinceDevTools

[![CI](https://github.com/princelundgren/prince-devtools/actions/workflows/ci.yml/badge.svg)](https://github.com/princelundgren/prince-devtools/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A macOS menu bar app that gathers a developer's everyday status and one-click actions in one
panel, in place of a menu bar app for each job.

**Status:** being built; there is no release yet. Its first tool is system health.

## What it does

- **One menu bar icon** that changes only when something needs attention.
- **System health** as a panel of cards: memory pressure, CPU averaged over minutes, free disk
  space, and your process count against the macOS limit, each against a threshold you can change
  in Settings.
- **When something is red**, a message names the problem and, where a process is behind it, the
  process most responsible, with an **Open Activity Monitor** button.
- **Cheap to run**: no idle CPU, about one wakeup a minute until the panel is first opened, low
  RAM.
- **Private**: no telemetry, analytics or crash reporting.

Later tools join the same panel, one at a time, each one you glance at or act on with one click.

## Requirements

macOS 26 or later.

## Design

The design, its decisions and their reasons:
[docs/superpowers/specs/2026-11-24-princedevtools-design.md](docs/superpowers/specs/2026-11-24-princedevtools-design.md).

## Help and contributing

- Questions and bugs: [open an issue](https://github.com/princelundgren/prince-devtools/issues).
- Security problems: report them privately, as the
  [security policy](https://github.com/princelundgren/prince-devtools/security/policy) says.
- Contributions: read the
  [contributing guide](https://github.com/princelundgren/.github/blob/main/CONTRIBUTING.md) first.

Maintained by [Prince Lundgren](https://github.com/princelundgren). MIT licensed; see
[LICENSE](LICENSE).
