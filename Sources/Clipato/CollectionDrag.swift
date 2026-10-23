import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CollectionDrag {
    static let assetType = UTType(exportedAs: "dev.freddon.framevault.collection-assets")
    static let folderType = UTType(exportedAs: "dev.freddon.framevault.collection-folder")

    static func provider(assets: Set<CollectionAsset>) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = L("\(assets.count) 项内容")
        provider.registerDataRepresentation(forTypeIdentifier: assetType.identifier, visibility: .ownProcess) { completion in
            do { completion(try JSONEncoder().encode(assets), nil) }
            catch { completion(nil, error) }
            return nil
        }
        return provider
    }

    static func provider(collection: AssetCollection) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = collection.name
        provider.registerDataRepresentation(forTypeIdentifier: folderType.identifier, visibility: .ownProcess) { completion in
            do { completion(try JSONEncoder().encode(collection.id), nil) }
            catch { completion(nil, error) }
            return nil
        }
        return provider
    }

    static func loadAssets(from provider: NSItemProvider, completion: @escaping @MainActor (Result<Set<CollectionAsset>, Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: assetType.identifier) { data, error in
            let result: Result<Set<CollectionAsset>, Error>
            if let error { result = .failure(error) }
            else if let data { result = Result { try JSONDecoder().decode(Set<CollectionAsset>.self, from: data) } }
            else { result = .failure(DragError.missingData) }
            Task { @MainActor in completion(result) }
        }
    }

    static func loadCollection(from provider: NSItemProvider, completion: @escaping @MainActor (Result<UUID, Error>) -> Void) {
        provider.loadDataRepresentation(forTypeIdentifier: folderType.identifier) { data, error in
            let result: Result<UUID, Error>
            if let error { result = .failure(error) }
            else if let data { result = Result { try JSONDecoder().decode(UUID.self, from: data) } }
            else { result = .failure(DragError.missingData) }
            Task { @MainActor in completion(result) }
        }
    }

    private enum DragError: LocalizedError {
        case missingData
        var errorDescription: String? { L("无法读取拖动的内容，请重新拖动。") }
    }
}

struct CollectionDragPreview: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Palette.accent)
            Text(count > 1 ? L("\(count) 项内容") : title)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(Palette.foreground)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1) }
        .fixedSize()
    }
}
