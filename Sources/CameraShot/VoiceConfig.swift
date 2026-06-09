// MARK: - RealtimeAudioConfig

struct RealtimeAudioConfig {
    static let model = "gpt-realtime-2"

    static let defaultPassivePrompt =
        "You are listening to live system audio from a conversation or meeting. Respond only when there is a question, request, decision point, or useful context to add. Be concise and practical."

    static let defaultInstantPrompt =
        "You are an instant voice assistant. The user will hold a push-to-talk button while relevant system audio plays, then release it. Answer or summarize the captured system audio directly and concisely."

    var passiveEnabled: Bool = false
    var instantEnabled: Bool = false
    var passiveSystemPrompt: String = Self.defaultPassivePrompt
    var instantSystemPrompt: String = Self.defaultInstantPrompt

    var enabled: Bool { passiveEnabled || instantEnabled }
}
