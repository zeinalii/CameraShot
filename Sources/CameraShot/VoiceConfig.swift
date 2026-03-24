// MARK: - VoiceConfig

struct VoiceConfig {
    var enabled:              Bool   = false
    var serverURL:            String = "ws://aseman:8765"
    var audioAIPrompt:        String = "You are listening to a live conversation or meeting. Based on the transcript, answer questions being asked, summarize key points, or provide helpful context. Be concise."
    var transcriptTokenLimit: Int    = 500
}
