// MARK: - RealtimeAudioConfig

struct RealtimeAudioConfig {
    static let model = "gpt-realtime-2.1"

    static let defaultPassivePrompt = ""

    static let defaultInstantPrompt = ""

    var passiveEnabled: Bool = false
    var instantEnabled: Bool = false
    var instant2Enabled: Bool = false
    var passiveSystemPrompt: String = Self.defaultPassivePrompt
    var instantSystemPrompt: String = Self.defaultInstantPrompt
    var instant2SystemPrompt: String = Self.defaultInstantPrompt

    var enabled: Bool { passiveEnabled || instantEnabled || instant2Enabled }
}
