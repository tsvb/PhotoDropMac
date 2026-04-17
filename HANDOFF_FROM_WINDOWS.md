# PhotoDrop — Handoff from Windows Claude Code session

> Saved verbatim from the Windows-side Claude Code handoff. Treat as reference only — the Mac port is going **native (Swift/SwiftUI)** rather than following the Avalonia playbook below.

## Repo state at handoff

- Origin: https://github.com/tsvb/PhotoDrop.git
- `main` tracking `origin/main`
- Commit `2a6f7c3` up

## Original (Avalonia) setup recipe — NOT the path we're taking

```bash
# 1. Install .NET 8 SDK
brew install --cask dotnet-sdk
dotnet --list-sdks    # confirm 8.x appears

# 2. Install Avalonia templates (one-time)
dotnet new install Avalonia.Templates

# 3. Clone
git clone https://github.com/tsvb/PhotoDrop.git
cd PhotoDrop

# 4. Verify Core builds + tests pass (WPF App will fail — expected on Mac)
dotnet build src/PhotoDrop.Core/PhotoDrop.Core.csproj
dotnet test  tests/PhotoDrop.Core.Tests/PhotoDrop.Core.Tests.csproj --nologo
```

## Original suggested first prompt

> Read CLAUDE.md and HANDOFF.md. Then start the macOS port following the suggested playbook — step 1, extract `IDriveWatcher` and `IDriveEjector` interfaces to Core and move the Windows implementations into a new `PhotoDrop.Platform.Windows` project so Core becomes truly platform-agnostic.

## Known caveat from the Windows session

A cloned macOS checkout will build `PhotoDrop.Core` fine but the `PhotoDrop.App` WPF project will fail (`net8.0-windows` TFM + WPF). Expected — that's the whole point of the port. Options mentioned:

- Comment `PhotoDrop.App` out of the `.sln` temporarily, or
- Add `<EnableWindowsTargeting>false</EnableWindowsTargeting>` work-arounds, or
- Just build `src/PhotoDrop.Core/` and run its tests until a replacement UI project exists.

## Our plan deviation

We're **not** using Avalonia. We're building a native macOS app with Swift + SwiftUI. The .NET `PhotoDrop.Core` codebase and `HANDOFF.md` in the cloned repo will be used as the **design reference / source of truth for behavior**, not as a library we link against.
