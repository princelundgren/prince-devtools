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
- **CI runs on GitHub's `xcode-27` runner** with Xcode 27.2 selected. Every action is pinned by
  full commit SHA, except the Claude review: it calls the shared reusable workflow at its moving
  `v1` tag, since only that repository's maintainer can move its `v*` tags.
- **CodeQL scans Swift and the workflows** (`.github/workflows/codeql.yml`). Its Swift scan runs on
  `macos-26` with Xcode 26.6, since CodeQL can't trace a build with Xcode 27.
- **Build and test** from the repository root:
  - `swift test --package-path PrinceDevToolsCore`
  - `scripts/install-xcodegen.sh`, then in `PrinceDevTools/`:
    `../build/tools/xcodegen/bin/xcodegen generate` and
    `xcodebuild -scheme PrinceDevTools -configuration Debug -derivedDataPath ../build/DerivedData CODE_SIGNING_ALLOWED=NO build`.
    The `.xcodeproj` is generated from `PrinceDevTools/project.yml` and not committed.
- **Dependencies:** Dependabot covers GitHub Actions and the core package. XcodeGen, pinned with its
  checksum in `scripts/install-xcodegen.sh`, and Sparkle, pinned by commit in
  `PrinceDevTools/project.yml`, are checked against their latest releases, with the release notes
  read, before each release. A Sparkle bump also copies its `LICENSE` over
  `PrinceDevTools/PrinceDevTools/ThirdPartyNotices.txt`, which the release checks.
- **Releases** run from a `v*` tag on `main` (`.github/workflows/release.yml`), after the CI
  workflow passes. A tag with a suffix (`v0.1.0-rc.1`) is a rehearsal: it uploads only the
  rehearsal appcast and makes no GitHub release. Never rename `release.yml`: Sparkle's build number
  is that workflow's run number. The app has no entitlements, and the release fails if the signed
  app carries any. The signing, notarization, Sparkle and upload secrets, and the `AWS_REGION`
  variable, go in the `release` environment; the maintainer sets them and pushes the tags.
