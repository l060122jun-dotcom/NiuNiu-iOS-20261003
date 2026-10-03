import SwiftUI
import UIKit
import MediaPlayer
import Combine

@MainActor final class PlaybackPreferences: ObservableObject {
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    static let holdRates: [Float] = [1.5, 2, 2.5, 3, 4]
    let videoID: String
    @Published var rate: Float { didSet { save(Double(rate), "rate", perVideo: false) } }
    @Published var holdRate: Float { didSet { save(Double(holdRate), "holdRate", perVideo: false) } }
    @Published var intro: Double { didSet { save(intro, "intro") } }
    @Published var outro: Double { didSet { save(outro, "outro") } }
    @Published var mode: String { didSet { UserDefaults.standard.set(mode, forKey: "playback.mode") } }
    @Published var timerMode = 0
    @Published var deadline: Date?
    @Published var countdown: Int?
    @Published var timerCancelledForSession = false
    init(videoID: String) {
        self.videoID = videoID
        let d = UserDefaults.standard
        let savedRate = Float(d.double(forKey: "playback.rate"))
        rate = Self.rates.contains(savedRate) ? savedRate : 1
        let savedHold = Float(d.double(forKey: "playback.holdRate"))
        holdRate = Self.holdRates.contains(savedHold) ? savedHold : 2
        intro = min(300, max(0, d.double(forKey: "playback.\(videoID).intro")))
        outro = min(300, max(0, d.double(forKey: "playback.\(videoID).outro")))
        let savedMode = d.string(forKey: "playback.mode") ?? "continuous"
        mode = ["continuous", "single", "loop"].contains(savedMode) ? savedMode : "continuous"
    }
    private func save(_ value: Double, _ key: String, perVideo: Bool = true) {
        UserDefaults.standard.set(value, forKey: perVideo ? "playback.\(videoID).\(key)" : "playback.\(key)")
    }
    func setTimer(_ mode: Int) {
        timerMode = mode; countdown = nil; timerCancelledForSession = false
        deadline = mode > 0 ? Date().addingTimeInterval(Double(mode * 60)) : nil
    }
    func cancelTimer() { timerMode = 0; deadline = nil; countdown = nil; timerCancelledForSession = true }
}

struct PlaybackSettingsView: View {
    @ObservedObject var settings: PlaybackPreferences
    let rateChanged: (Float) -> Void
    @State private var brightness = Double(UIScreen.main.brightness)
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("系统显示与音量") {
                    VStack(alignment: .leading) {
                        Label("屏幕亮度", systemImage: "sun.max")
                        Slider(value: $brightness, in: 0...1).onChange(of: brightness) { UIScreen.main.brightness = CGFloat($0) }
                    }
                    VStack(alignment: .leading) { Label("系统媒体音量", systemImage: "speaker.wave.2"); PlaybackVolumeView().frame(height: 32) }
                }
                Section("倍速") {
                    Picker("普通倍速", selection: $settings.rate) {
                        ForEach(PlaybackPreferences.rates, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }.onChange(of: settings.rate, perform: rateChanged)
                    Picker("长按倍速", selection: $settings.holdRate) {
                        ForEach(PlaybackPreferences.holdRates, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    Text("长按播放器下方手势区临时加速，松手恢复；不覆盖系统进度条或画中画按钮。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本影片跳过设置（0–300 秒）") {
                    skip("片头", value: $settings.intro)
                    skip("片尾", value: $settings.outro)
                    Text("每部影片分别保存。片尾到达后按播放模式结束；不足以容纳片头片尾的短视频不自动跳过。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("播放方式") {
                    Picker("播放模式", selection: $settings.mode) {
                        Text("连续播放").tag("continuous"); Text("单集停止").tag("single"); Text("单集循环").tag("loop")
                    }
                }
                Section("定时停止") {
                    Picker("停止时间", selection: Binding(get: { settings.timerMode }, set: { settings.setTimer($0) })) {
                        Text("不开启").tag(0); Text("本集播完").tag(-1)
                        Text("30 分钟").tag(30); Text("60 分钟").tag(60); Text("90 分钟").tag(90)
                    }
                    if let date = settings.deadline { Text("到时：\(date.formatted(date: .omitted, time: .shortened))；停止前可在 10 秒倒计时中取消。") }
                    if settings.timerMode != 0 { Button("取消定时停止") { settings.cancelTimer() } }
                }
                Section {
                    NavigationLink("硬件解码说明") {
                        Text("本应用使用系统 AVPlayer。硬件解码由 iOS 按设备能力、媒体编码与系统状态自动决定；应用无法强制切换硬件或软件解码，因此不提供无效的开关。若播放失败，请尝试换源或反馈。")
                            .padding().navigationTitle("硬件解码")
                    }
                }
            }.navigationTitle("播放设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func skip(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Stepper("跳过\(title) \(Int(value.wrappedValue)) 秒", value: value, in: 0...300, step: 1)
            Slider(value: value, in: 0...300, step: 1)
        }
    }
}

private struct PlaybackVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let view = MPVolumeView(); view.showsRouteButton = false; return view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
