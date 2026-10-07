import Foundation

extension ButtonAction: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "leftClick": self = .leftClick
        case "rightClick": self = .rightClick
        case "middleClick": self = .middleClick
        case "forward": self = .forward
        case "backward": self = .backward
        case "doubleClick": self = .doubleClick
        case "fireButton": self = .fireButton
        case "easyAim": self = .easyAim
        case "scrollUp": self = .scrollUp
        case "scrollDown": self = .scrollDown
        case "dpiCycle": self = .dpiCycle
        case "dpiUp": self = .dpiUp
        case "dpiDown": self = .dpiDown
        case "profileCycle": self = .profileCycle
        case "shortcut": self = .shortcut(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        case "macro": self = .macro(try c.decodeIfPresent(String.self, forKey: .value) ?? "")
        default: self = .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leftClick: try c.encode("leftClick", forKey: .type)
        case .rightClick: try c.encode("rightClick", forKey: .type)
        case .middleClick: try c.encode("middleClick", forKey: .type)
        case .forward: try c.encode("forward", forKey: .type)
        case .backward: try c.encode("backward", forKey: .type)
        case .doubleClick: try c.encode("doubleClick", forKey: .type)
        case .fireButton: try c.encode("fireButton", forKey: .type)
        case .easyAim: try c.encode("easyAim", forKey: .type)
        case .scrollUp: try c.encode("scrollUp", forKey: .type)
        case .scrollDown: try c.encode("scrollDown", forKey: .type)
        case .dpiCycle: try c.encode("dpiCycle", forKey: .type)
        case .dpiUp: try c.encode("dpiUp", forKey: .type)
        case .dpiDown: try c.encode("dpiDown", forKey: .type)
        case .profileCycle: try c.encode("profileCycle", forKey: .type)
        case .shortcut(let v):
            try c.encode("shortcut", forKey: .type)
            try c.encode(v, forKey: .value)
        case .macro(let v):
            try c.encode("macro", forKey: .type)
            try c.encode(v, forKey: .value)
        case .off: try c.encode("off", forKey: .type)
        }
    }
}
