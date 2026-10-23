import CoreGraphics

enum ImageGridCropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func resized(_ rect: CGRect, translation: CGSize, within size: CGSize) -> CGRect {
        let extendsRight = self == .topRight || self == .bottomRight
        let extendsDown = self == .bottomLeft || self == .bottomRight
        let anchor = CGPoint(x: extendsRight ? rect.minX : rect.maxX,
                             y: extendsDown ? rect.minY : rect.maxY)
        let availableSide = min(extendsRight ? size.width - anchor.x : anchor.x,
                                extendsDown ? size.height - anchor.y : anchor.y).rounded(.down)
        let delta = ((extendsRight ? translation.width : -translation.width)
                     + (extendsDown ? translation.height : -translation.height)) / 2
        let side = min(max(1, rect.width + delta.rounded()), availableSide)
        return CGRect(x: extendsRight ? anchor.x : anchor.x - side,
                      y: extendsDown ? anchor.y : anchor.y - side,
                      width: side, height: side)
    }

    static func hit(at point: CGPoint, in rect: CGRect, radius: CGFloat) -> Self? {
        guard radius >= 0 else { return nil }
        var nearest: Self?
        var nearestDistance = CGFloat.infinity
        for corner in allCases {
            let position = corner.point(in: rect)
            let dx = point.x - position.x
            let dy = point.y - position.y
            let distance = dx * dx + dy * dy
            if distance <= radius * radius, distance < nearestDistance {
                nearest = corner
                nearestDistance = distance
            }
        }
        return nearest
    }
}
