# Coach Cutups — Project Conventions

## Workflow for non-trivial features

Each feature goes through a four-stage loop, with adversarial review at every artifact handoff:

1. **Brainstorm → spec** (`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`)
2. **Adversarial review on the spec** — see "Review pattern" below. Apply fixes, then commit.
3. **Write plan** (`docs/superpowers/plans/YYYY-MM-DD-<topic>.md`)
4. **Adversarial review on the plan** — same pattern. Apply fixes, then commit.
5. **Compact the conversation before plan execution.** Plans get long; execution dispatches many subagents and consumes context fast. Start the execution phase with fresh context — re-read the plan + spec + this file rather than relying on accumulated chat history.
6. **Execute** via `superpowers:subagent-driven-development` (fresh subagent per task).
7. **Adversarial review on the shipped code changes** — apply fixes, then commit.
8. **Backlog deferred items** to `BACKLOG.md` at the worktree root.

## Review pattern (use for specs, plans, and shipped code)

For each review pass, spawn **two adversarial agents in parallel**:

- **Simplify agent** — find every place the design / plan / code is more complex than it needs to be. Recommended subagent: `general-purpose`. Frame as "adversarial simplification review."
- **Code-review / correctness agent** — find correctness bugs, fragile patterns, things that pass tests today but break tomorrow. Recommended subagent: `feature-dev:code-reviewer` for code; `general-purpose` for specs/plans.

Both agents get:
- The artifact under review (spec, plan, or diff range)
- The relevant codebase reference paths (so they can verify claims, not just trust the artifact)
- The full "user values" block (below)

After both reviews return:

1. **Group similar findings** across the two reviews.
2. **Spawn one deliberation agent per group** (in parallel). Each agent's job:
   - Research all issues in its group against the codebase
   - For each issue, decide the best long-term fix
   - Adversarial self-review of its own conclusions
   - **Defer to human** if the right fix isn't obvious
3. **Apply / skip per group**:
   - **APPLY** when the fix is strictly better than the original
   - **SKIP** when the fix is worse than the original issue (every change must earn its place)
   - **DEFER** when judgment is required from the human
4. Surface anything deferred at the end.

## User values (paste into every adversarial review prompt)

- Best long-term design over short-term tradeoffs
- It's OK to change adjacent code if it helps get to the best long-term design
- Simplicity — avoid over-engineered systems and fixes
- Don't care about effort or severity
- Care about long-term codebase quality and maintainability
- Don't need to fix every single race condition or edge case if they're super rare unless the fix has zero tradeoffs
- Pay close attention to fixes that add complexity — the fix needs to be worth it
- Every change must earn its place; if the fix is worse than the original issue, skip it
- Leave the code in a better place than we found it

## Build + test conventions

- **Core package tests:** `swift test --package-path apple/VideoCoachCore`
- **App build:** the `.xcodeproj` is gitignored, regenerated from `apple/project.yml`. After creating any new file under `apple/App/**`:
  ```
  cd apple && xcodegen generate && cd ..
  xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
  ```
- Core package files under `apple/VideoCoachCore/**` are auto-discovered by SwiftPM — no xcodegen needed.

## Architecture notes

- **`VideoCoachCore`** (Swift Package) holds all pure logic: data model, clock semantics, custom AVFoundation compositor, export pipeline. Tested headlessly via `swift test`.
- **App target** (`apple/App/`) is SwiftUI + AppKit interop. Workspace is `@Observable @MainActor`; ContentView owns ephemeral UI state (`@State` + `@Binding` to children).
- **`Workspace` is project-data only** — never put pure UI mode flags on it. Inspector mode, modal-flow flags, etc. live on `ContentView` as `@State`.
- **Custom compositor lives on the export path only.** Preview playback uses AVFoundation's built-in compositor because macOS 26 strips custom-compositor instruction subclasses (`ClipPreviewBuilder.swift` documents this). Overlays in preview live as AppKit overlay views above `AVPlayerView`.
- **Project file is `project.json` under the project folder**, plus a `recordings/` subdir of `.mov` clips. `formatVersion` discipline: bump on every additive schema change; migration happens at decode time, never at save.

## Backlog

Carry deferred items in `BACKLOG.md` (worktree root). Format: numbered list under headings (Spec/plan corrections, Code follow-ups, UX gaps). Each entry includes "Why deferred" and "When to revisit."
