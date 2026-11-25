# PrinceDevTools: agent instructions

Everything in this repository is public: code, docs, commit messages, issues and pull requests.

- **Nothing personal or employer-specific.** No machine names, host names, account IDs or
  organisation names, in code, tests, fixtures, screenshots, docs or commits. Use placeholders.
- **The design is the authority:** `docs/superpowers/specs/2026-11-24-princedevtools-design.md`.
  A change that makes it untrue updates it in the same commit.
- **Privacy is a product feature.** No telemetry, analytics, crash reporting or SDK that collects
  any of them. The app has no entitlements.
- **No subprocesses.** The app reads the kernel through its APIs and opens other apps only through
  `NSWorkspace`.
- **Changes land through a pull request**, with signed commits.
- **Build and test** from the repository root:
  - `swift test --package-path PrinceDevToolsCore`
  - `scripts/install-xcodegen.sh`, then in `PrinceDevTools/`:
    `../build/tools/xcodegen/bin/xcodegen generate` and
    `xcodebuild -scheme PrinceDevTools -configuration Debug -derivedDataPath ../build/DerivedData CODE_SIGNING_ALLOWED=NO build`.
    The `.xcodeproj` is generated from `PrinceDevTools/project.yml` and not committed.
