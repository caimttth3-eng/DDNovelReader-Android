import Flutter
import AVFoundation

/// iOS 离线系统语音（AVSpeechSynthesizer），对应 Dart 端
/// `com.ddnovelreader/system_tts` 通道：initialize / speak / stop，
/// 并通过 start / range / done / error 回传状态与逐词位置。
public class SystemSpeechPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {
  private let channel: FlutterMethodChannel
  private let synthesizer = AVSpeechSynthesizer()
  private var requestId: String?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    synthesizer.delegate = self
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.ddnovelreader/system_tts",
      binaryMessenger: registrar.messenger())
    let instance = SystemSpeechPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      // 系统语音无需异步初始化，返回默认语言即可。
      result(AVSpeechSynthesisVoice.currentLanguageCode())

    case "voices":
      let voices = AVSpeechSynthesisVoice.speechVoices().map { voice -> [String: String] in
        [
          "id": voice.identifier,
          "name": voice.name,
          "lang": voice.language,
          "quality": qualityName(voice.quality),
          "gender": genderName(voice.gender),
        ]
      }
      result(voices)

    case "speak":
      guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String,
            let text = args["text"] as? String, !text.isEmpty else {
        result(FlutterError(code: "empty_text", message: "No speech text", details: nil))
        return
      }
      let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1.0
      stopInternal()
      requestId = id
      let utterance = AVSpeechUtterance(string: text)
      if let voiceId = args["voice"] as? String,
         let selected = AVSpeechSynthesisVoice(identifier: voiceId) {
        // 用户在音源面板里明确选择的系统音色（可能是"优化音质"音色）。
        utterance.voice = selected
      } else {
        // 未指定时：中文书优先中文音色（设备语言是英文时也能正确朗读），否则跟随系统。
        let sample = text.prefix(64).unicodeScalars
        let hasCJK = sample.contains { scalar in
          (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
        let preferred = hasCJK ? "zh-CN" : AVSpeechSynthesisVoice.currentLanguageCode()
        let lang = AVSpeechSynthesisVoice(language: preferred) != nil ? preferred : AVSpeechSynthesisVoice.currentLanguageCode()
        if let voice = AVSpeechSynthesisVoice(language: lang) {
          utterance.voice = voice
        }
      }
      // AVSpeech 默认语速 0.5，对应本 App 的 1.0x。
      utterance.rate = Float(min(max(0.5 * rate, 0.05), 1.0))
      utterance.pitchMultiplier = 1.0
      synthesizer.speak(utterance)
      result(nil)

    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      result(true)

    case "stop":
      stopInternal()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stopInternal() {
    requestId = nil
    if synthesizer.isSpeaking || synthesizer.isPaused {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
    if #available(iOS 16.0, *), quality == .premium { return "premium" }
    switch quality {
    case .enhanced: return "enhanced"
    default: return "default"
    }
  }

  private func genderName(_ gender: AVSpeechSynthesisVoiceGender) -> String {
    switch gender {
    case .male: return "male"
    case .female: return "female"
    default: return ""
    }
  }

  private func send(_ method: String, _ args: [String: Any]) {
    channel.invokeMethod(method, arguments: args)
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    guard let id = requestId else { return }
    send("start", ["id": id])
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let id = requestId else { return }
    requestId = nil
    send("done", ["id": id])
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    // stop() 已清空 requestId；用户停止不需要再上报。
  }

  public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange,
    utterance: AVSpeechUtterance
  ) {
    guard let id = requestId else { return }
    send("range", [
      "id": id,
      "start": characterRange.location,
      "end": characterRange.location + characterRange.length,
    ])
  }
}
