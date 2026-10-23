import Foundation

extension SavedSession {
    func frameURL(at index: Int) throws -> URL {
        guard manifest.frames.indices.contains(index) else {
            throw KeyframeExportError.invalidManifest(L("所选关键帧已不存在。"))
        }
        let file = manifest.frames[index].file
        let source = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = source.appendingPathComponent(file).standardizedFileURL.resolvingSymlinksInPath()
        guard !file.hasPrefix("/"), url.path.hasPrefix(source.path + "/"), url.pathExtension.lowercased() == "png" else {
            throw KeyframeExportError.invalidManifest(L("关键帧文件必须是录制目录内的 PNG 图片。"))
        }
        return url
    }
}
