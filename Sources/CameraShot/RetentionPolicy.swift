import Foundation

enum RetentionPolicy {
    /// Full-size capture files kept on disk for the current session.
    static let screenshotFileLimit = 30

    /// Rendered Visual tab entries kept in the WebView DOM.
    static let visualRenderedEntryLimit = 60

    /// Rendered Audio AI entries kept in the WebView DOM.
    static let audioAIRenderedEntryLimit = 80

    /// Rendered Opencode chat entries kept in the WebView DOM.
    static let opencodeRenderedEntryLimit = 160

    /// How often the app asks native and WebView state to prune old retained data.
    static let memoryMaintenanceInterval: TimeInterval = 120

    /// Safety cap for Visual scripts that accumulate only before the page is ready.
    static let pendingVisualScriptLimit = 500

    /// Safety cap for standalone Visual entries that accumulate only before the page is ready.
    static let pendingVisualEntryLimit = visualRenderedEntryLimit

    /// File Explore icon cache limit; icons are cheap to recreate.
    static let fileExploreIconCacheLimit = 256
}
