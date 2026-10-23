import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chinese = [.simplifiedChinese, .traditionalChinese].contains(LanguageSettings.shared.resolvedLanguage)
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text(L("隐私")).consoleFont(18, weight: .semibold)
                Spacer()
                Picker(L("语言"), selection: $chinese) {
                    Text("English").tag(false)
                    Text("简体中文").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityIdentifier("privacy-policy-language")
            }
            ScrollView {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(verbatim: text)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("privacy-policy-text")
                }
            }
            .consoleFont(12)
            HStack {
                Spacer()
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("close-privacy-policy")
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .tint(Palette.accent)
        .consoleTypography()
        .task(id: chinese) {
            do {
                let name = chinese ? "PrivacyPolicy.zh-CN" : "PrivacyPolicy.en"
                guard let url = LanguageSettings.resourceBundle.url(forResource: name, withExtension: "txt") else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".txt"])
                }
                text = try String(contentsOf: url, encoding: .utf8)
                errorMessage = nil
            } catch {
                text = ""
                errorMessage = error.localizedDescription
            }
        }
    }
}
