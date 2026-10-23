import SwiftUI

struct BatchRenameView: View {
    @ObservedObject var model: AppModel
    let library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale
    @State private var rule = BatchRenameRule()
    @State private var urls: [URL] = []
    @State private var filenames: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            rules.padding(24)
            preview
                .padding(.horizontal, 24).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background).foregroundStyle(Palette.foreground).tint(Palette.accent)
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
        .accessibilityIdentifier("batch-rename-page")
        .onAppear(perform: updatePreview)
        .onChange(of: rule) { _, _ in updatePreview() }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Text(L("按当前列表顺序递增命名，保留原扩展名。"))
                    .consoleFont(12).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("\(urls.count) 项")).consoleFont(11, weight: .medium)
                    .foregroundStyle(Palette.muted).fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Palette.card, in: Capsule())
            }
            if !model.externalRenameURLs.isEmpty {
                Label(L("将直接重命名外部原文件，不会导入保管箱。"), systemImage: "info.circle")
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("前缀")).consoleFont(11, weight: .medium).foregroundStyle(Palette.muted)
                    TextField(L("前缀"), text: $rule.prefix)
                        .accessibilityIdentifier("batch-rename-prefix")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150 * max(1, fontScale)), spacing: 16)],
                          alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("起始数字")).consoleFont(11, weight: .medium).foregroundStyle(Palette.muted)
                        TextField(L("起始数字"), value: $rule.start, format: .number.grouping(.never))
                            .accessibilityIdentifier("batch-rename-start")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("递增步长")).consoleFont(11, weight: .medium).foregroundStyle(Palette.muted)
                        TextField(L("递增步长"), value: $rule.increment, format: .number.grouping(.never))
                            .accessibilityIdentifier("batch-rename-increment")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("数字位数")).consoleFont(11, weight: .medium).foregroundStyle(Palette.muted)
                        Menu {
                            Picker(L("数字位数"), selection: $rule.digits) {
                                Text("1").tag(0)
                                Text("01").tag(2)
                                Text("001").tag(3)
                                Text("0001").tag(4)
                                Text("000001").tag(6)
                            }.pickerStyle(.inline)
                        } label: {
                            HStack(spacing: 8) {
                                Text(rule.digits == 0 ? "1" : String(repeating: "0", count: rule.digits - 1) + "1")
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.down").consoleFont(9, weight: .medium)
                            }
                            .consoleFont(12).foregroundStyle(Palette.foreground)
                            .padding(.horizontal, 8).frame(height: 22 * max(1, fontScale))
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 5))
                            .overlay { SurfaceBorder(cornerRadius: 5) }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel(L("数字位数"))
                        .accessibilityIdentifier("batch-rename-digits")
                    }
                }
            }
            .consoleFont(12)
            .textFieldStyle(.roundedBorder)
            .environment(\.isFocusEffectEnabled, true)
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay { SurfaceBorder(cornerRadius: 10) }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                Text(L("原名称")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("新名称")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .consoleFont(11, weight: .medium).foregroundStyle(Palette.muted)
            .padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(urls.indices, id: \.self) { index in
                        HStack(spacing: 18) {
                            Text(urls[index].lastPathComponent).foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(urls[index].lastPathComponent)
                            Text(filenames.indices.contains(index) ? filenames[index] : "—")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(filenames.indices.contains(index) ? filenames[index] : "—")
                        }
                        .consoleFont(12).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .accessibilityElement(children: .combine)
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { SurfaceBorder(cornerRadius: 10) }
        .accessibilityIdentifier("batch-rename-preview")
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                errorMessage
                Spacer(minLength: 0)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                errorMessage
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Palette.card)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    @ViewBuilder private var errorMessage: some View {
        if let error {
            Text(error).consoleFont(12).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.batchRenameAssets.allSatisfy({ if case .image = $0 { return true }; return false }) {
                Button(L("返回上一步")) { model.returnToImageProcessingInput() }
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("batch-rename-back")
            } else {
                Button(L("取消")) { model.dismissImageProcessing() }
                    .buttonStyle(QuietButtonStyle())
            }
            Button(L("应用命名"), action: apply)
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(filenames.count != urls.count || urls.isEmpty)
                .accessibilityIdentifier("batch-rename-apply")
        }
    }

    private func updatePreview() {
        do {
            urls = try model.batchRenameSourceURLs()
            filenames = try rule.filenames(for: urls)
            error = nil
        } catch {
            filenames = []
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        do { try model.batchRename(rule: rule) }
        catch { self.error = error.localizedDescription }
    }
}
