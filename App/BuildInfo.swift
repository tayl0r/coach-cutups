import Foundation

/// Build-time identification baked in by `scripts/run.sh`. The script
/// rewrites this file with the current short git SHA and timestamp before
/// each `xcodebuild`, then restores the placeholder afterward so the
/// working tree stays clean. `ContentView` reads `BuildInfo.commit` and
/// renders it as the window's navigation subtitle so the user can verify
/// which build is actually running.
enum BuildInfo {
    static let commit: String = "dev"
    static let builtAt: String = ""
}
