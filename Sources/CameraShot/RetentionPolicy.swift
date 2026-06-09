import Foundation

enum RetentionPolicy {
    /// Full-size capture files kept on disk for the current session.
    static let screenshotFileLimit = 30

    /// Rendered Visual tab entries kept in the WebView DOM.
    static let visualRenderedEntryLimit = 60

    /// Rendered Audio AI entries kept in the WebView DOM.
    static let audioAIRenderedEntryLimit = 80

    /// Rendered Instant Voice entries kept in the WebView DOM.
    static let instantVoiceRenderedEntryLimit = 80

    /// Rendered Chat entries kept in the WebView DOM.
    static let chatRenderedEntryLimit = 160

    /// Rendered Opencode chat entries kept in the WebView DOM.
    static let opencodeRenderedEntryLimit = 160

    /// How often the app asks native and WebView state to prune old retained data.
    static let memoryMaintenanceInterval: TimeInterval = 120

    /// Safety cap for Visual scripts that accumulate only before the page is ready.
    static let pendingVisualScriptLimit = 500

    /// Safety cap for standalone Visual entries that accumulate only before the page is ready.
    static let pendingVisualEntryLimit = visualRenderedEntryLimit

    /// Safety caps for Opencode chat state that accumulates only before its WebView is ready.
    static let pendingOpencodeChatEntryLimit = opencodeRenderedEntryLimit
    static let pendingOpencodeScriptLimit = 500

    /// Defensive caps for malformed or stalled streaming responses.
    static let sseLineBufferLimitBytes = 1_000_000
    static let sseDataLineLimit = 128
    static let httpErrorBodyLimitBytes = 256_000

    /// Maximum native text retained for one still-open streaming entry.
    static let streamingTextBufferLimit = 200_000

    /// File Explore icon cache limit; icons are cheap to recreate.
    static let fileExploreIconCacheLimit = 256
}
