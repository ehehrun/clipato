import SwiftUI

struct AddToCollectionMenu: View {
    @ObservedObject var library: LibraryStore
    let assets: Set<CollectionAsset>
    let onError: (Error) -> Void

    var body: some View {
        if library.collections.isEmpty {
            Text(L("请先在侧栏新建收藏夹"))
        } else {
            ForEach(library.collections) { collection in
                let members = library.collectionMembers[collection.id, default: []]
                let addedCount = assets.reduce(0) { count, asset in
                    count + (members.contains(asset) ? 1 : 0)
                }
                let allAdded = !assets.isEmpty && addedCount == assets.count
                Button {
                    do { try library.addToCollection(collection.id, assets: assets) }
                    catch { onError(error) }
                } label: {
                    if allAdded {
                        Label(L("\(collection.name)（已加入）"), systemImage: "checkmark")
                    } else if addedCount > 0 {
                        Label(L("\(collection.name)（已加入 \(addedCount)/\(assets.count)）"), systemImage: "minus")
                    } else {
                        Label {
                            Text(collection.name)
                        } icon: {
                            Image(systemName: collection.color == nil ? "folder" : "folder.fill")
                                .foregroundStyle(collection.color?.color ?? Palette.muted)
                        }
                    }
                }
                .disabled(assets.isEmpty || allAdded)
            }
        }
    }
}
