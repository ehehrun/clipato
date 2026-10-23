import Darwin
import Foundation

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let flags = FileManager.default.fileExists(atPath: destination) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
let result = source.withCString { sourcePath in
    destination.withCString { destinationPath in
        renamex_np(sourcePath, destinationPath, flags)
    }
}
if result != 0 {
    let message = "Clipato build: 应用替换失败，旧应用保持完整：\(String(cString: strerror(errno)))\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
