import UIKit

/// 十套配色。每套都备了浅色与深色两份语义色，切换主题时键盘、候选条、
/// 工具面板一起换，不需要分别改。
///
/// 色值不是随手挑的：正文色对背景 ≥ 7:1（AAA），次要文字 ≥ 4.5:1，
/// 主按钮上的文字对主色 ≥ 4.5:1——十套全部实测通过（见 Tools/ThemeContrast 校验）。
enum LianaColorway: String, CaseIterable, Codable {
    case mist
    case graphite
    case paper
    case celadon
    case ink
    case pine
    case sakura
    case salt
    case mocha
    case mono

    /// 语义角色。名字与 LianaPalette 的属性一一对应。
    enum Role {
        case background, card, soft, ink, muted, stroke, primary, onPrimary, keyboard, key, pressed, utility, shadow
    }

    var title: String {
        switch self {
        case .mist: return "雾白"
        case .graphite: return "石墨"
        case .paper: return "宣纸"
        case .celadon: return "天青"
        case .ink: return "墨蓝"
        case .pine: return "松林"
        case .sakura: return "樱花"
        case .salt: return "海盐"
        case .mocha: return "咖啡"
        case .mono: return "极简"
        }
    }

    var note: String {
        switch self {
        case .mist: return "中性灰绿，最不打扰的默认色"
        case .graphite: return "纯灰阶，层叠靠明度"
        case .paper: return "米黄纸感，长文不刺眼"
        case .celadon: return "宋式青瓷与月白，安静留白"
        case .ink: return "深靛与冷灰，Linear 式克制"
        case .pine: return "护眼绿，夜里最柔和"
        case .sakura: return "粉灰与砖红，轻但不甜"
        case .salt: return "清透蓝白，干净利落"
        case .mocha: return "暖褐与奶油，木质书桌"
        case .mono: return "纯黑白，对比最强"
        }
    }

    /// 一套主题里的某个角色色值。
    func color(_ role: Role, dark: Bool) -> UIColor {
        let hex: UInt32
        switch (self, role) {
        case (.mist, .background): hex = dark ? 0x101112 : 0xF5F5F2
        case (.mist, .card): hex = dark ? 0x1B1D1F : 0xFFFFFF
        case (.mist, .soft): hex = dark ? 0x282A2C : 0xECEDE9
        case (.mist, .ink): hex = dark ? 0xF3F3EF : 0x191B1D
        case (.mist, .muted): hex = dark ? 0xB3B7B9 : 0x64686A
        case (.mist, .stroke): hex = dark ? 0x3B3E40 : 0xDDDFDC
        case (.mist, .primary): hex = dark ? 0xEDEEE9 : 0x202224
        case (.mist, .onPrimary): hex = dark ? 0x17191B : 0xFFFFFF
        case (.mist, .keyboard): hex = dark ? 0x17191B : 0xE5E7E6
        case (.mist, .key): hex = dark ? 0x303335 : 0xFFFFFF
        case (.mist, .pressed): hex = dark ? 0x505557 : 0xC4C8C7
        case (.mist, .utility): hex = dark ? 0x222527 : 0xCFD3D1
        case (.mist, .shadow): hex = dark ? 0x080909 : 0x9DA3A0
        case (.graphite, .background): hex = dark ? 0x0E0E0E : 0xF6F6F6
        case (.graphite, .card): hex = dark ? 0x191919 : 0xFFFFFF
        case (.graphite, .soft): hex = dark ? 0x262626 : 0xE9E9E9
        case (.graphite, .ink): hex = dark ? 0xF2F2F2 : 0x111111
        case (.graphite, .muted): hex = dark ? 0xA8A8A8 : 0x5C5C5C
        case (.graphite, .stroke): hex = dark ? 0x333333 : 0xD6D6D6
        case (.graphite, .primary): hex = dark ? 0xE8E8E8 : 0x1A1A1A
        case (.graphite, .onPrimary): hex = dark ? 0x121212 : 0xFFFFFF
        case (.graphite, .keyboard): hex = dark ? 0x141414 : 0xE2E2E2
        case (.graphite, .key): hex = dark ? 0x2B2B2B : 0xFFFFFF
        case (.graphite, .pressed): hex = dark ? 0x4A4A4A : 0xC0C0C0
        case (.graphite, .utility): hex = dark ? 0x1F1F1F : 0xCBCBCB
        case (.graphite, .shadow): hex = dark ? 0x000000 : 0x9A9A9A
        case (.paper, .background): hex = dark ? 0x1A1713 : 0xF6F1E6
        case (.paper, .card): hex = dark ? 0x23201A : 0xFFFDF8
        case (.paper, .soft): hex = dark ? 0x2E2A22 : 0xEDE6D6
        case (.paper, .ink): hex = dark ? 0xF2ECE0 : 0x2A241C
        case (.paper, .muted): hex = dark ? 0xB0A695 : 0x6E6354
        case (.paper, .stroke): hex = dark ? 0x3D382E : 0xDCD3C1
        case (.paper, .primary): hex = dark ? 0xEAE2D2 : 0x3A3126
        case (.paper, .onPrimary): hex = dark ? 0x1A1713 : 0xFFFDF8
        case (.paper, .keyboard): hex = dark ? 0x191612 : 0xEBE3D3
        case (.paper, .key): hex = dark ? 0x2B2720 : 0xFFFDF8
        case (.paper, .pressed): hex = dark ? 0x48423A : 0xCFC5B2
        case (.paper, .utility): hex = dark ? 0x221E19 : 0xDED5C3
        case (.paper, .shadow): hex = dark ? 0x0A0908 : 0xA89C86
        case (.celadon, .background): hex = dark ? 0x0F1716 : 0xF2F6F4
        case (.celadon, .card): hex = dark ? 0x18211F : 0xFFFFFF
        case (.celadon, .soft): hex = dark ? 0x202B29 : 0xE3EDE9
        case (.celadon, .ink): hex = dark ? 0xEAF1EE : 0x1F2E2B
        case (.celadon, .muted): hex = dark ? 0xA5BAB3 : 0x5A6E68
        case (.celadon, .stroke): hex = dark ? 0x2E3C38 : 0xCFDDD7
        case (.celadon, .primary): hex = dark ? 0xDCE8E3 : 0x2F4A44
        case (.celadon, .onPrimary): hex = dark ? 0x12201C : 0xFFFFFF
        case (.celadon, .keyboard): hex = dark ? 0x121A18 : 0xDFE9E5
        case (.celadon, .key): hex = dark ? 0x243029 : 0xFFFFFF
        case (.celadon, .pressed): hex = dark ? 0x3C4C46 : 0xB9CCC5
        case (.celadon, .utility): hex = dark ? 0x1A2320 : 0xC9D9D3
        case (.celadon, .shadow): hex = dark ? 0x050908 : 0x93A99F
        case (.ink, .background): hex = dark ? 0x0C0E14 : 0xF4F5F8
        case (.ink, .card): hex = dark ? 0x151821 : 0xFFFFFF
        case (.ink, .soft): hex = dark ? 0x1E2230 : 0xE8EAF0
        case (.ink, .ink): hex = dark ? 0xE9EBF2 : 0x1B1D24
        case (.ink, .muted): hex = dark ? 0x9AA0B0 : 0x5F6474
        case (.ink, .stroke): hex = dark ? 0x2A2F40 : 0xD5D8E2
        case (.ink, .primary): hex = dark ? 0x8C97F2 : 0x3D45A0
        case (.ink, .onPrimary): hex = dark ? 0x0C0E14 : 0xFFFFFF
        case (.ink, .keyboard): hex = dark ? 0x0D1017 : 0xE8EAF0
        case (.ink, .key): hex = dark ? 0x232839 : 0xFFFFFF
        case (.ink, .pressed): hex = dark ? 0x39405A : 0xC3C8D8
        case (.ink, .utility): hex = dark ? 0x1A1E2A : 0xD2D6E2
        case (.ink, .shadow): hex = dark ? 0x04050A : 0x9BA2B8
        case (.pine, .background): hex = dark ? 0x0D130F : 0xF1F5F1
        case (.pine, .card): hex = dark ? 0x151D17 : 0xFFFFFF
        case (.pine, .soft): hex = dark ? 0x1F2A21 : 0xE1EAE2
        case (.pine, .ink): hex = dark ? 0xE7EFE8 : 0x19251B
        case (.pine, .muted): hex = dark ? 0xA3B5A6 : 0x59685C
        case (.pine, .stroke): hex = dark ? 0x2C3A2F : 0xCFDCCF
        case (.pine, .primary): hex = dark ? 0xCFE3D3 : 0x2C5A3A
        case (.pine, .onPrimary): hex = dark ? 0x10200F : 0xFFFFFF
        case (.pine, .keyboard): hex = dark ? 0x101711 : 0xDDE8DE
        case (.pine, .key): hex = dark ? 0x232E25 : 0xFFFFFF
        case (.pine, .pressed): hex = dark ? 0x3B4B3E : 0xB9CDBC
        case (.pine, .utility): hex = dark ? 0x18201A : 0xC9DBCB
        case (.pine, .shadow): hex = dark ? 0x040705 : 0x97AC9A
        case (.sakura, .background): hex = dark ? 0x171012 : 0xFBF4F4
        case (.sakura, .card): hex = dark ? 0x211A1C : 0xFFFFFF
        case (.sakura, .soft): hex = dark ? 0x2B2224 : 0xF5E7E8
        case (.sakura, .ink): hex = dark ? 0xF4E9EA : 0x2A1F20
        case (.sakura, .muted): hex = dark ? 0xBFAEB0 : 0x7A6466
        case (.sakura, .stroke): hex = dark ? 0x3E3134 : 0xEAD5D7
        case (.sakura, .primary): hex = dark ? 0xEBCFD2 : 0x8C4A52
        case (.sakura, .onPrimary): hex = dark ? 0x1A1214 : 0xFFFFFF
        case (.sakura, .keyboard): hex = dark ? 0x151012 : 0xF3E4E5
        case (.sakura, .key): hex = dark ? 0x2A2224 : 0xFFFFFF
        case (.sakura, .pressed): hex = dark ? 0x46393C : 0xDDC3C5
        case (.sakura, .utility): hex = dark ? 0x201A1C : 0xE9D6D8
        case (.sakura, .shadow): hex = dark ? 0x080506 : 0xB89EA0
        case (.salt, .background): hex = dark ? 0x0B1218 : 0xF3F7FA
        case (.salt, .card): hex = dark ? 0x131C24 : 0xFFFFFF
        case (.salt, .soft): hex = dark ? 0x1B2731 : 0xE4EEF5
        case (.salt, .ink): hex = dark ? 0xE8F0F6 : 0x16232E
        case (.salt, .muted): hex = dark ? 0x9FB2C0 : 0x56697A
        case (.salt, .stroke): hex = dark ? 0x26343F : 0xCCDCE7
        case (.salt, .primary): hex = dark ? 0xCFE3F0 : 0x245E7C
        case (.salt, .onPrimary): hex = dark ? 0x0C1A22 : 0xFFFFFF
        case (.salt, .keyboard): hex = dark ? 0x0E161C : 0xDFEAF2
        case (.salt, .key): hex = dark ? 0x1F2A33 : 0xFFFFFF
        case (.salt, .pressed): hex = dark ? 0x33424E : 0xB7CCDB
        case (.salt, .utility): hex = dark ? 0x141D24 : 0xC7DAE6
        case (.salt, .shadow): hex = dark ? 0x03070A : 0x94AAB8
        case (.mocha, .background): hex = dark ? 0x17120E : 0xF7F2EC
        case (.mocha, .card): hex = dark ? 0x201A15 : 0xFFFCF8
        case (.mocha, .soft): hex = dark ? 0x2A221B : 0xEFE5DA
        case (.mocha, .ink): hex = dark ? 0xF3EBE1 : 0x2A2119
        case (.mocha, .muted): hex = dark ? 0xBBAE9F : 0x6F6053
        case (.mocha, .stroke): hex = dark ? 0x3B3128 : 0xDFD2C3
        case (.mocha, .primary): hex = dark ? 0xE8D9C8 : 0x5B4130
        case (.mocha, .onPrimary): hex = dark ? 0x1A130E : 0xFFFFFF
        case (.mocha, .keyboard): hex = dark ? 0x15100C : 0xEDE2D6
        case (.mocha, .key): hex = dark ? 0x282019 : 0xFFFCF8
        case (.mocha, .pressed): hex = dark ? 0x443930 : 0xD2C2AF
        case (.mocha, .utility): hex = dark ? 0x1E1813 : 0xDED0BF
        case (.mocha, .shadow): hex = dark ? 0x070504 : 0xA6957F
        case (.mono, .background): hex = dark ? 0x000000 : 0xFFFFFF
        case (.mono, .card): hex = dark ? 0x111111 : 0xFFFFFF
        case (.mono, .soft): hex = dark ? 0x1C1C1C : 0xF0F0F0
        case (.mono, .ink): hex = dark ? 0xFFFFFF : 0x000000
        case (.mono, .muted): hex = dark ? 0xA0A0A0 : 0x666666
        case (.mono, .stroke): hex = dark ? 0x2E2E2E : 0xD9D9D9
        case (.mono, .primary): hex = dark ? 0xFFFFFF : 0x000000
        case (.mono, .onPrimary): hex = dark ? 0x000000 : 0xFFFFFF
        case (.mono, .keyboard): hex = dark ? 0x0A0A0A : 0xE9E9E9
        case (.mono, .key): hex = dark ? 0x222222 : 0xFFFFFF
        case (.mono, .pressed): hex = dark ? 0x3D3D3D : 0xC7C7C7
        case (.mono, .utility): hex = dark ? 0x161616 : 0xD4D4D4
        case (.mono, .shadow): hex = dark ? 0x000000 : 0x999999
        }
        return UIColor(red: CGFloat((hex >> 16) & 255)/255,
                       green: CGFloat((hex >> 8) & 255)/255,
                       blue: CGFloat(hex & 255)/255,
                       alpha: 1)
    }
}
