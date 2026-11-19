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
        ["id": voice.identifier, "name": voice.name, "lang": voice.language]
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
      // 跟随系统语言；无效时交给合成器选默认音色。
      if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) {
        utterance.voice = voice
      }
      // AVSpeech 默认语速 0.5，对应本 App 的 1.0x。
      utterance.rate = Float(min(max(0.5 * rate, 0.05), 1.0))
      utterance.pitchMultiplier = 1.0
      synthesizer.speak(utterance)
      result(nil)

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
