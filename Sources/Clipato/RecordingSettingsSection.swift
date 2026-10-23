import SwiftUI

struct RecordingSettingsSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.consoleFontScale) private var fontScale
    @Environment(\.locale) private var locale
    @State private var isRecording = false
    @State private var showAdvanced = false
    @State private var customThresholdSelected = false
    @FocusState private var customThresholdFocused: Bool

    private static let thresholdValues = [0.01, 0.025, 0.05]
    private var thresholdFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimum = 0.5
        formatter.maximum = 12
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }

    private var usesCustomThreshold: Bool {
        customThresholdSelected || !Self.thresholdValues.contains(model.threshold)
    }

    private var parametersDisabled: Bool {
        isRecording || model.recordingBusy || model.selectingRecordingRegion
    }

    var body: some View {
        Section {
            Picker(L("录制方式"), selection: $model.recordingMode) {
                Text(L("直接录 · MP4")).tag(RecordingMode.video)
                Text(L("关键帧")).tag(RecordingMode.keyframes)
            }
            .pickerStyle(.segmented)
            .disabled(parametersDisabled)
            .accessibilityIdentifier("recording-mode")
            Text(model.recordingMode == .video
                 ? L("连续录制所选区域，保存为 MP4。")
                 : L("画面变化时保存新帧，静止时延长上一帧。保留 PNG、时间轴与播放器，可导出 MP4 / GIF。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
            Text(L("录屏不支持录音，主要用于后续按帧截取图片。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
            DisclosureGroup(L("高级选项"), isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.recordingMode == .keyframes {
                        Picker(L("采样频率"), selection: $model.sampleRate) {
                            Text(L("1 帧 / 秒")).tag(1.0)
                            Text(L("2 帧 / 秒")).tag(2.0)
                            Text(L("4 帧 / 秒")).tag(4.0)
                        }
                    } else {
                        Picker(L("视频帧率"), selection: $model.videoFrameRate) {
                            Text(L("15 帧 / 秒")).tag(15.0)
                            Text(L("30 帧 / 秒")).tag(30.0)
                            Text(L("60 帧 / 秒")).tag(60.0)
                        }
                    }
                    Picker(L("最长边"), selection: $model.maxDimension) {
                        Text("1280 px").tag(1280)
                        Text("1920 px").tag(1920)
                        Text("2560 px").tag(2560)
                    }
                    if model.recordingMode == .keyframes {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Text(L("变化阈值"))
                                Spacer(minLength: 0)
                                Text(model.threshold, format: .percent.precision(.fractionLength(0...2)))
                                    .consoleFont(11, design: .monospaced)
                                    .frame(width: 44 * fontScale, alignment: .trailing)
                            }
                            Picker(L("变化阈值"), selection: Binding<Double?>(get: {
                                usesCustomThreshold ? nil : model.threshold
                            }, set: { value in
                                customThresholdSelected = value == nil
                                customThresholdFocused = value == nil
                                if let value { model.threshold = value }
                            })) {
                                ForEach(Self.thresholdValues, id: \.self) { value in
                                    Text(value, format: .percent.precision(.fractionLength(0...1)))
                                        .tag(Optional(value))
                                }
                                Text(L("自定义")).tag(Double?.none)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .accessibilityLabel(L("变化阈值"))
                            if usesCustomThreshold {
                                HStack(spacing: 8) {
                                    Text(L("自定义")).consoleFont(12)
                                    TextField(L("变化阈值"), value: Binding(get: {
                                        model.threshold * 100
                                    }, set: { model.threshold = $0 / 100 }), formatter: thresholdFormatter)
                                        .textFieldStyle(.roundedBorder).labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 80 * max(1, fontScale))
                                        .environment(\.isFocusEffectEnabled, true)
                                        .focused($customThresholdFocused)
                                        .accessibilityLabel(L("变化阈值"))
                                    Text("%").foregroundStyle(Palette.muted)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("0.5%–12%")
                                Text(L("越低越敏感"))
                            }.consoleFont(11).foregroundStyle(Palette.muted)
                        }
                    }
                    Text(L("框选后可调整范围；绿框标记录制区域。浮动条可暂停、继续与停止，暂停不计时。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
                .padding(.top, 10)
                .disabled(parametersDisabled)
            }
            .accessibilityIdentifier("recording-advanced-options")
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(L("录屏"))
                Spacer(minLength: 12)
                Text(L("默认用于下一次录屏。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
            }
        }
        .onReceive(model.recorder.$isRecording.removeDuplicates()) { isRecording = $0 }
    }
}
