import AppKit
import CoreText
import Foundation
import QuartzCore

@MainActor
final class GuideAnimationScene {
    let layer: CALayer
    let viewBox: CGRect
    let duration: Double

    init(svg: String) throws {
        let document = GuideSVGDocument()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = document
        guard parser.parse(), let root = document.root, root.name == "svg" else {
            if let error = parser.parserError { throw error }
            throw GuideSVGError.invalid("SVG document")
        }
        let rootKeys: Set<String> = ["xmlns", "width", "height", "viewBox", "role", "aria-label", "id"]
        guard Set(root.attributes.keys).isSubset(of: rootKeys) else { throw GuideSVGError.unsupported("svg attributes") }
        let box = try GuideSVGBuilder.numbers(root.attributes["viewBox"], count: 4, field: "viewBox")
        guard box[2] > 0, box[3] > 0 else { throw GuideSVGError.invalid("viewBox size") }
        viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        layer = CALayer()
        layer.name = "guide-scene"
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = viewBox
        let builder = GuideSVGBuilder()
        try builder.appendChildren(of: root, to: layer, transform: .identity, style: GuideSVGBuilder.defaultStyle)
        duration = builder.duration ?? 0
    }
}

private enum GuideSVGError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let field): return "Invalid guide SVG: \(field)."
        case .unsupported(let element): return "Unsupported guide SVG: \(element)."
        }
    }
}

private final class GuideSVGNode {
    let name: String
    let attributes: [String: String]
    var children: [GuideSVGNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private final class GuideSVGDocument: NSObject, XMLParserDelegate {
    var root: GuideSVGNode?
    private var stack: [GuideSVGNode] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let node = GuideSVGNode(name: name, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) }
        else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }
}

@MainActor
private final class GuideSVGBuilder {
    static let defaultStyle = ["fill": "#000", "stroke": "none", "stroke-width": "1",
                               "stroke-linecap": "butt", "stroke-linejoin": "miter",
                               "font-size": "16", "font-weight": "400", "text-anchor": "start"]
    private static let styleKeys: Set<String> = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
                                                  "stroke-dasharray", "font-family", "font-size", "font-weight", "text-anchor"]
    private static let commonKeys: Set<String> = styleKeys.union(["id", "transform", "opacity"])
    private(set) var duration: Double?
    private var serial = 0

    func appendChildren(of node: GuideSVGNode, to parent: CALayer,
                        transform: CGAffineTransform, style: [String: String]) throws {
        for child in node.children where child.name != "animate" && child.name != "animateTransform" {
            try append(child, to: parent, transform: transform, style: style)
        }
    }

    private func append(_ node: GuideSVGNode, to parent: CALayer,
                        transform: CGAffineTransform, style inherited: [String: String]) throws {
        if node.name == "title" { return }
        let geometryKeys: Set<String>
        switch node.name {
        case "g": geometryKeys = []
        case "rect": geometryKeys = ["x", "y", "width", "height", "rx", "ry"]
        case "ellipse": geometryKeys = ["cx", "cy", "rx", "ry"]
        case "circle": geometryKeys = ["cx", "cy", "r"]
        case "polyline", "polygon": geometryKeys = ["points"]
        case "path": geometryKeys = ["d"]
        case "text": geometryKeys = ["x", "y"]
        default: throw GuideSVGError.unsupported(node.name)
        }
        let unknown = Set(node.attributes.keys).subtracting(Self.commonKeys.union(geometryKeys))
        guard unknown.isEmpty else { throw GuideSVGError.unsupported("\(node.name) attributes \(unknown.sorted())") }
        var style = inherited
        for key in Self.styleKeys where node.attributes[key] != nil { style[key] = node.attributes[key] }
        let animations = try node.children.filter { $0.name == "animate" || $0.name == "animateTransform" }.map(track)
        guard Set(animations.map(\.attribute)).count == animations.count else { throw GuideSVGError.invalid("duplicate animation property") }
        let baseTransform = try Self.transform(node.attributes["transform"])
        let opacity = try Self.scalar(node.attributes["opacity"] ?? "1", field: "opacity")
        guard (0...1).contains(opacity) else { throw GuideSVGError.invalid("opacity") }

        if node.name == "g" {
            if animations.isEmpty && opacity == 1 {
                try appendChildren(of: node, to: parent, transform: baseTransform.concatenating(transform), style: style)
                return
            }
            let group = container(named: node.attributes["id"], kind: "g", transform: transform, parent: parent)
            group.opacity = Float(opacity)
            group.setAffineTransform(baseTransform)
            for animation in animations {
                switch animation.attribute {
                case "transform": try applyTransform(animation, to: group)
                case "opacity": try applyScalar(animation, to: group, keyPath: "opacity")
                default: throw GuideSVGError.unsupported("g animation \(animation.attribute)")
                }
            }
            try appendChildren(of: node, to: group, transform: .identity, style: style)
            return
        }

        var graphicParent = parent
        var graphicTransform = baseTransform.concatenating(transform)
        let transformTrack = animations.first { $0.attribute == "transform" }
        if let transformTrack {
            let group = container(named: nil, kind: "\(node.name)-transform", transform: transform, parent: parent)
            try applyTransform(transformTrack, to: group)
            graphicParent = group
            graphicTransform = .identity
        }
        let graphic: CALayer
        if node.name == "text" {
            guard node.children.allSatisfy({ $0.name == "animate" || $0.name == "animateTransform" }) else {
                throw GuideSVGError.unsupported("nested text")
            }
            graphic = try textLayer(node, style: style, transform: graphicTransform)
        } else {
            guard node.children.allSatisfy({ $0.name == "animate" || $0.name == "animateTransform" }) else {
                throw GuideSVGError.unsupported("nested \(node.name)")
            }
            graphic = try shapeLayer(node, style: style, transform: graphicTransform)
        }
        serial += 1
        graphic.name = node.attributes["id"] ?? "\(node.name)-\(serial)"
        graphic.opacity = Float(opacity)
        graphicParent.addSublayer(graphic)
        for animation in animations where animation.attribute != "transform" {
            switch animation.attribute {
            case "opacity": try applyScalar(animation, to: graphic, keyPath: "opacity")
            case "fill":
                guard let shape = graphic as? CAShapeLayer else { throw GuideSVGError.unsupported("text fill animation") }
                let values = try animation.values.map { try Self.color($0) }
                guard values.allSatisfy({ $0 != nil }) else { throw GuideSVGError.invalid("animated fill") }
                shape.fillColor = values[0]!
                add(animation, values: values.map { $0! }, keyPath: "fillColor", to: shape)
            case "cx":
                guard node.name == "circle" else { throw GuideSVGError.unsupported("cx animation on \(node.name)") }
                let original = try Self.scalar(node.attributes["cx"] ?? "0", field: "cx")
                let values = try animation.values.map { value -> NSNumber in
                    let x = try Self.scalar(value, field: "cx")
                    return NSNumber(value: Double(graphic.position.x + (x - original) * graphicTransform.a))
                }
                graphic.position.x = CGFloat(truncating: values[0])
                add(animation, values: values, keyPath: "position.x", to: graphic)
            default: throw GuideSVGError.unsupported("animation \(animation.attribute)")
            }
        }
    }

    private func container(named name: String?, kind: String, transform: CGAffineTransform, parent: CALayer) -> CALayer {
        let holder: CALayer
        if transform.isIdentity { holder = parent }
        else {
            holder = CALayer()
            holder.name = "\(name ?? kind)-static-transform"
            holder.anchorPoint = .zero
            holder.setAffineTransform(transform)
            parent.addSublayer(holder)
        }
        let group = CALayer()
        serial += 1
        group.name = name ?? "\(kind)-\(serial)"
        group.anchorPoint = .zero
        group.allowsGroupOpacity = true
        holder.addSublayer(group)
        return group
    }

    private func shapeLayer(_ node: GuideSVGNode, style: [String: String], transform: CGAffineTransform) throws -> CAShapeLayer {
        let path = CGMutablePath()
        func number(_ key: String, default value: String? = nil) throws -> CGFloat {
            try Self.scalar(node.attributes[key] ?? value, field: "\(node.name).\(key)")
        }
        switch node.name {
        case "rect":
            let rect = try CGRect(x: number("x", default: "0"), y: number("y", default: "0"),
                                  width: number("width"), height: number("height"))
            guard rect.width >= 0, rect.height >= 0 else { throw GuideSVGError.invalid("rect size") }
            let rx = try number("rx", default: node.attributes["ry"] ?? "0")
            let ry = try number("ry", default: node.attributes["rx"] ?? "0")
            guard rx >= 0, ry >= 0 else { throw GuideSVGError.invalid("rect radius") }
            path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
        case "circle", "ellipse":
            let cx = try number("cx", default: "0"), cy = try number("cy", default: "0")
            let rx = try number(node.name == "circle" ? "r" : "rx")
            let ry: CGFloat
            if node.name == "circle" { ry = rx }
            else { ry = try number("ry") }
            guard rx >= 0, ry >= 0 else { throw GuideSVGError.invalid("ellipse radius") }
            path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        case "polyline", "polygon":
            let values = try Self.numbers(node.attributes["points"], field: "points")
            guard values.count >= 4, values.count.isMultiple(of: 2) else { throw GuideSVGError.invalid("points") }
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for index in stride(from: 2, to: values.count, by: 2) { path.addLine(to: CGPoint(x: values[index], y: values[index + 1])) }
            if node.name == "polygon" { path.closeSubpath() }
        case "path": try Self.appendPath(node.attributes["d"], to: path)
        default: throw GuideSVGError.unsupported(node.name)
        }
        let shape = CAShapeLayer()
        shape.path = path
        shape.fillColor = try Self.color(style["fill"]!)
        shape.strokeColor = try Self.color(style["stroke"]!)
        shape.lineWidth = try Self.scalar(style["stroke-width"], field: "stroke-width")
        guard shape.lineWidth >= 0 else { throw GuideSVGError.invalid("stroke-width") }
        switch style["stroke-linecap"]! {
        case "butt": shape.lineCap = .butt
        case "round": shape.lineCap = .round
        case "square": shape.lineCap = .square
        default: throw GuideSVGError.unsupported("stroke-linecap")
        }
        switch style["stroke-linejoin"]! {
        case "miter": shape.lineJoin = .miter
        case "round": shape.lineJoin = .round
        case "bevel": shape.lineJoin = .bevel
        default: throw GuideSVGError.unsupported("stroke-linejoin")
        }
        if let dash = style["stroke-dasharray"] {
            let values = try Self.numbers(dash, field: "stroke-dasharray")
            guard !values.isEmpty, values.allSatisfy({ $0 > 0 }) else { throw GuideSVGError.invalid("stroke-dasharray") }
            shape.lineDashPattern = values.map { NSNumber(value: Double($0)) }
        }
        let bounds = path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
        place(shape, bounds: bounds, transform: transform)
        return shape
    }

    private func textLayer(_ node: GuideSVGNode, style: [String: String], transform: CGAffineTransform) throws -> CATextLayer {
        if let family = style["font-family"],
           !["Hiragino Sans GB,PingFang SC,system-ui,sans-serif", "system-ui", "sans-serif"].contains(family) {
            throw GuideSVGError.unsupported("font-family")
        }
        guard style["stroke"] == "none", let fill = try Self.color(style["fill"]!) else {
            throw GuideSVGError.unsupported("text fill or stroke")
        }
        let size = try Self.scalar(style["font-size"], field: "font-size")
        guard size > 0, let base = CTFontCreateUIFontForLanguage(.system, size, "zh-Hans" as CFString) else {
            throw GuideSVGError.invalid("font-size or system font")
        }
        let weight: CGFloat
        switch style["font-weight"]! {
        case "400": weight = NSFont.Weight.regular.rawValue
        case "500": weight = NSFont.Weight.medium.rawValue
        case "600": weight = NSFont.Weight.semibold.rawValue
        default: throw GuideSVGError.unsupported("font-weight")
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let string = NSAttributedString(string: node.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = try Self.scalar(node.attributes["x"] ?? "0", field: "text.x")
        let y = try Self.scalar(node.attributes["y"] ?? "0", field: "text.y")
        let anchor: CGFloat
        switch style["text-anchor"]! {
        case "start": anchor = 0
        case "middle": anchor = width / 2
        case "end": anchor = width
        default: throw GuideSVGError.unsupported("text-anchor")
        }
        let text = CATextLayer()
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 1
        text.string = node.text
        text.font = font
        text.fontSize = size
        text.foregroundColor = fill
        text.alignmentMode = .left
        text.isWrapped = false
        text.truncationMode = .none
        place(text, bounds: CGRect(x: x - anchor, y: y - ascent, width: ceil(width), height: ceil(ascent + descent + leading)),
              transform: transform)
        text.bounds.origin = .zero
        return text
    }

    private func place(_ layer: CALayer, bounds: CGRect, transform: CGAffineTransform) {
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: bounds.origin, size: bounds.size)
        layer.position = bounds.origin.applying(transform)
        layer.setAffineTransform(CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0))
    }

    private struct Track {
        let attribute: String
        let type: String?
        let values: [String]
        let keyTimes: [NSNumber]
        let timingFunctions: [CAMediaTimingFunction]
        let duration: Double
    }

    private func track(_ node: GuideSVGNode) throws -> Track {
        let keys: Set<String> = ["attributeName", "type", "values", "keyTimes", "calcMode", "keySplines", "dur", "begin", "repeatCount"]
        guard Set(node.attributes.keys).isSubset(of: keys), node.children.isEmpty,
              let attribute = node.attributes["attributeName"], let rawValues = node.attributes["values"],
              let rawTimes = node.attributes["keyTimes"], let rawDuration = node.attributes["dur"], rawDuration.hasSuffix("s"),
              node.attributes["begin"] == "indefinite", node.attributes["repeatCount"] == "indefinite" else {
            throw GuideSVGError.invalid("animation attributes")
        }
        let seconds = Double(try Self.scalar(String(rawDuration.dropLast()), field: "duration"))
        guard seconds > 0 else { throw GuideSVGError.invalid("duration") }
        if let duration, duration != seconds { throw GuideSVGError.unsupported("mixed animation durations") }
        duration = seconds
        let values = rawValues.components(separatedBy: ";")
        let times = try rawTimes.components(separatedBy: ";").map { try Self.scalar($0, field: "keyTimes") }
        guard values.count >= 2, times.count == values.count, times.first == 0, times.last == 1,
              zip(times, times.dropFirst()).allSatisfy({ $0.0 <= $0.1 }) else { throw GuideSVGError.invalid("animation keyTimes") }
        let timing: [CAMediaTimingFunction]
        switch node.attributes["calcMode"] ?? "linear" {
        case "linear": timing = []
        case "spline":
            guard let splines = node.attributes["keySplines"] else { throw GuideSVGError.invalid("keySplines") }
            let segments = try splines.components(separatedBy: ";").map { try Self.numbers($0, count: 4, field: "keySplines") }
            guard segments.count == values.count - 1,
                  segments.allSatisfy({ (0...1).contains($0[0]) && (0...1).contains($0[2]) }) else {
                throw GuideSVGError.invalid("keySplines")
            }
            timing = segments.map { CAMediaTimingFunction(controlPoints: Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
        default: throw GuideSVGError.unsupported("animation calcMode")
        }
        if node.name == "animateTransform" {
            guard attribute == "transform", let type = node.attributes["type"], ["translate", "scale"].contains(type) else {
                throw GuideSVGError.unsupported("animateTransform")
            }
        } else if attribute == "transform" || node.attributes["type"] != nil {
            throw GuideSVGError.unsupported("animate transform")
        }
        return Track(attribute: attribute, type: node.attributes["type"], values: values,
                     keyTimes: times.map { NSNumber(value: Double($0)) }, timingFunctions: timing, duration: seconds)
    }

    private func add(_ track: Track, values: [Any], keyPath: String, to layer: CALayer) {
        guard !track.values.dropFirst().allSatisfy({ $0 == track.values[0] }) else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = track.keyTimes
        animation.calculationMode = .linear
        animation.timingFunctions = track.timingFunctions
        animation.duration = track.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: track.attribute)
    }

    private func applyTransform(_ track: Track, to layer: CALayer) throws {
        let transforms = try track.values.map { value -> CATransform3D in
            let numbers = try Self.numbers(value, field: "animated transform")
            guard (1...2).contains(numbers.count) else { throw GuideSVGError.invalid("animated transform") }
            let affine: CGAffineTransform
            if track.type == "translate" {
                affine = CGAffineTransform(translationX: numbers[0], y: numbers.count == 2 ? numbers[1] : 0)
            } else {
                affine = CGAffineTransform(scaleX: numbers[0], y: numbers.count == 2 ? numbers[1] : numbers[0])
            }
            return CATransform3DMakeAffineTransform(affine)
        }
        layer.transform = transforms[0]
        add(track, values: transforms.map { NSValue(caTransform3D: $0) }, keyPath: "transform", to: layer)
    }

    private func applyScalar(_ track: Track, to layer: CALayer, keyPath: String) throws {
        let values = try track.values.map { try Self.scalar($0, field: track.attribute) }
        guard values.allSatisfy({ (0...1).contains($0) }) else { throw GuideSVGError.invalid(track.attribute) }
        layer.opacity = Float(values[0])
        add(track, values: values.map { NSNumber(value: Double($0)) }, keyPath: keyPath, to: layer)
    }

    static func scalar(_ string: String?, field: String) throws -> CGFloat {
        guard let string, let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            throw GuideSVGError.invalid(field)
        }
        return CGFloat(value)
    }

    static func numbers(_ string: String?, count: Int? = nil, field: String) throws -> [CGFloat] {
        guard let string else { throw GuideSVGError.invalid(field) }
        let values = try string.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { try scalar(String($0), field: field) }
        guard !values.isEmpty, count == nil || values.count == count else { throw GuideSVGError.invalid(field) }
        return values
    }

    private static func transform(_ string: String?) throws -> CGAffineTransform {
        guard let string else { return .identity }
        let expression = try NSRegularExpression(pattern: #"(translate|scale)\s*\(([^)]*)\)"#)
        let source = string as NSString
        let matches = expression.matches(in: string, range: NSRange(location: 0, length: source.length))
        var result = CGAffineTransform.identity
        var end = 0
        for match in matches {
            guard source.substring(with: NSRange(location: end, length: match.range.location - end)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuideSVGError.unsupported("transform")
            }
            let values = try numbers(source.substring(with: match.range(at: 2)), field: "transform")
            guard (1...2).contains(values.count) else { throw GuideSVGError.invalid("transform") }
            let next = source.substring(with: match.range(at: 1)) == "translate"
                ? CGAffineTransform(translationX: values[0], y: values.count == 2 ? values[1] : 0)
                : CGAffineTransform(scaleX: values[0], y: values.count == 2 ? values[1] : values[0])
            result = next.concatenating(result)
            end = NSMaxRange(match.range)
        }
        guard end > 0, source.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuideSVGError.unsupported("transform")
        }
        return result
    }

    private static func color(_ string: String) throws -> CGColor? {
        if string == "none" { return nil }
        guard string.hasPrefix("#"), [4, 7].contains(string.count), let value = UInt32(string.dropFirst(), radix: 16) else {
            throw GuideSVGError.unsupported("color \(string)")
        }
        let r: UInt32, g: UInt32, b: UInt32
        if string.count == 4 { r = (value >> 8) * 17; g = ((value >> 4) & 15) * 17; b = (value & 15) * 17 }
        else { r = value >> 16; g = (value >> 8) & 255; b = value & 255 }
        return CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func appendPath(_ source: String?, to path: CGMutablePath) throws {
        guard let source else { throw GuideSVGError.invalid("path.d") }
        let expression = try NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
        let original = source as NSString
        let matches = expression.matches(in: source, range: NSRange(location: 0, length: original.length))
        var tokens: [String] = []
        var previous = 0
        for match in matches {
            let gap = original.substring(with: NSRange(location: previous, length: match.range.location - previous))
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw GuideSVGError.invalid("path.d") }
            tokens.append(original.substring(with: match.range))
            previous = NSMaxRange(match.range)
        }
        guard original.substring(from: previous).allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw GuideSVGError.invalid("path.d") }
        guard let first = tokens.first, first == "M" || first == "m" else { throw GuideSVGError.invalid("path initial move") }
        var index = 0
        var command = ""
        var point = CGPoint.zero
        var start = CGPoint.zero
        while index < tokens.count {
            if tokens[index].first!.isLetter {
                command = tokens[index]
                index += 1
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    point = start
                    command = ""
                    continue
                }
            }
            guard ["M", "m", "L", "l", "H", "h", "V", "v"].contains(command) else { throw GuideSVGError.unsupported("path command \(command)") }
            let count = ["H", "h", "V", "v"].contains(command) ? 1 : 2
            guard index + count <= tokens.count else { throw GuideSVGError.invalid("path coordinates") }
            let first = try scalar(tokens[index], field: "path coordinate")
            let second: CGFloat
            if count == 2 { second = try scalar(tokens[index + 1], field: "path coordinate") }
            else { second = 0 }
            index += count
            let relative = command == command.lowercased()
            switch command.uppercased() {
            case "M", "L": point = CGPoint(x: first + (relative ? point.x : 0), y: second + (relative ? point.y : 0))
            case "H": point.x = first + (relative ? point.x : 0)
            case "V": point.y = first + (relative ? point.y : 0)
            default: throw GuideSVGError.invalid("path command")
            }
            if command.uppercased() == "M" {
                path.move(to: point)
                start = point
                command = relative ? "l" : "L"
            } else { path.addLine(to: point) }
        }
    }
}
