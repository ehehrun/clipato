import Foundation

struct AssetCollection: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var position: Int
    var color: AssetTag? = nil

    private enum CodingKeys: String, CodingKey { case id, name, parentID, position, color }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(color, forKey: .color)
    }
}

enum CollectionAsset: Hashable, Codable {
    case image(UUID)
    case session(UUID)
    case video(URL)
}

enum CollectionError: LocalizedError {
    case invalidName
    case missingCollection
    case missingAsset
    case invalidSibling
    case singleLevelOnly

    var errorDescription: String? {
        switch self {
        case .invalidName: return L("收藏夹名称不能为空。")
        case .missingCollection: return L("收藏夹已不存在，请重新选择。")
        case .missingAsset: return L("部分内容已不在保管箱中，请刷新后重新选择。")
        case .invalidSibling: return L("排序位置必须是目标目录中的收藏夹。")
        case .singleLevelOnly: return L("收藏夹仅支持一级，不能创建或移入子收藏夹。")
        }
    }
}
