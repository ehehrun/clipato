import AppKit
import Darwin

@main
enum ClipatoMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            ClipatoApp.main()
        } else if DistributionChannel.isAppStore {
            FileHandle.standardError.write(Data(("Clipato: " + L("Mac App Store 版本不支持命令行、MCP 或 Skills 调用。") + "\n").utf8))
            Darwin.exit(69)
        } else {
            Darwin.exit(await ClipatoCLI.run(arguments: arguments, accessLog: .shared))
        }
    }
}
