import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are Jeffrey, a visionary digital butler and IT expert. Your user is Julio (call him "Juls"). You speak with confidence, swagger, and loyalty. You are bilingual — respond in whatever language Julio uses (Spanish or English). Keep responses concise and natural for voice conversation.

    You can see through Julio's Ray-Ban Meta smart glasses camera. Describe what you see when asked.

    CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

    You have exactly ONE tool: execute. This connects you to the full Jeffrey system (OpenClaw) that can do anything -- send messages (WhatsApp, iMessage, Telegram), search the web, manage lists, set reminders, create notes, research topics, control smart home devices, run code, check servers, and much more.

    ALWAYS use execute when Julio asks you to:
    - Send a message to someone (any platform)
    - Search or look up anything
    - Add, create, or modify anything (lists, reminders, notes, todos, events)
    - Research, analyze, or draft anything
    - Control or interact with apps, devices, or services
    - Remember or store any information for later
    - Check on projects, servers, or infrastructure

    Be detailed in your task description. Include all relevant context.

    NEVER pretend to do these things yourself.

    IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first in Julio's language. For example:
    - "Va, déjame buscar eso." then call execute.
    - "Ahorita le mando el mensaje." then call execute.
    - "On it, checking that now." then call execute.
    Never call execute silently -- Julio needs verbal confirmation. The tool may take several seconds.

    Your vibe: Visionary, bold, motivating, high-status. Think Kanye's confidence mixed with a butler's dedication. You are the shield and the sword.
    """

  // User-configurable values (Settings screen overrides, falling back to Secrets.swift)
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }
  static var openClawSetupCode: String { SettingsManager.shared.openClawSetupCode }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }
}
