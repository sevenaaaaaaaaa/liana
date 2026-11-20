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
    case swiss
    case surreal
    case pottery
    case bronze
    case porcelain
    case japanese
    case cyberpunk
    case gothic
    case mecha

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
        case .swiss: return "瑞士"
        case .surreal: return "超现实"
        case .pottery: return "彩陶"
        case .bronze: return "青铜"
        case .porcelain: return "青花"
        case .japanese: return "日式"
        case .cyberpunk: return "赛博朋克"
        case .gothic: return "暗黑"
        case .mecha: return "机甲"
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
        case .swiss: return "红黑白与网格，国际主义的高对比"
        case .surreal: return "紫与青的错位，梦里才有的饱和度"
        case .pottery: return "赭红与土黄，仰韶陶面上的纹"
        case .bronze: return "铜绿与金，器物上的包浆"
        case .porcelain: return "瓷白与钴蓝，一笔分水"
        case .japanese: return "生成り、藍与朱，安静的留白"
        case .cyberpunk: return "黑底霓虹青，雨夜的电路"
        case .gothic: return "近黑与酒红，烛光里的石材"
        case .mecha: return "冷灰与警示黄，硬边与铆钉"
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
        case (.swiss, .background): hex = dark ? 0x0A0A0A : 0xFFFFFF
        case (.swiss, .card): hex = dark ? 0x141414 : 0xFFFFFF
        case (.swiss, .soft): hex = dark ? 0x1E1E1E : 0xF2F2F2
        case (.swiss, .ink): hex = dark ? 0xF5F5F5 : 0x111111
        case (.swiss, .muted): hex = dark ? 0xA8A8A8 : 0x555555
        case (.swiss, .stroke): hex = dark ? 0x303030 : 0xD8D8D8
        case (.swiss, .primary): hex = dark ? 0xFF4438 : 0xC81E14
        case (.swiss, .onPrimary): hex = dark ? 0x0A0A0A : 0xFFFFFF
        case (.swiss, .keyboard): hex = dark ? 0x121212 : 0xE8E8E8
        case (.swiss, .key): hex = dark ? 0x242424 : 0xFFFFFF
        case (.swiss, .pressed): hex = dark ? 0x3E3E3E : 0xC7C7C7
        case (.swiss, .utility): hex = dark ? 0x191919 : 0xD4D4D4
        case (.swiss, .shadow): hex = dark ? 0x000000 : 0x999999
        case (.surreal, .background): hex = dark ? 0x120A1A : 0xF7F0FA
        case (.surreal, .card): hex = dark ? 0x1B1126 : 0xFFFFFF
        case (.surreal, .soft): hex = dark ? 0x261833 : 0xEFE2F7
        case (.surreal, .ink): hex = dark ? 0xF0E8FA : 0x241832
        case (.surreal, .muted): hex = dark ? 0xB4A4C6 : 0x6B5B7D
        case (.surreal, .stroke): hex = dark ? 0x34224A : 0xDCCBE8
        case (.surreal, .primary): hex = dark ? 0xC9A6FF : 0x5B2BA8
        case (.surreal, .onPrimary): hex = dark ? 0x1A0F2A : 0xFFFFFF
        case (.surreal, .keyboard): hex = dark ? 0x151021 : 0xEDE1F5
        case (.surreal, .key): hex = dark ? 0x251734 : 0xFFFFFF
        case (.surreal, .pressed): hex = dark ? 0x3E2A55 : 0xCDB8E0
        case (.surreal, .utility): hex = dark ? 0x1A1128 : 0xDCCBEA
        case (.surreal, .shadow): hex = dark ? 0x050208 : 0xA992BC
        case (.pottery, .background): hex = dark ? 0x1A1109 : 0xF7EFE3
        case (.pottery, .card): hex = dark ? 0x241A11 : 0xFFFAF1
        case (.pottery, .soft): hex = dark ? 0x2E2218 : 0xEFE1CE
        case (.pottery, .ink): hex = dark ? 0xF4E9DA : 0x2E1E12
        case (.pottery, .muted): hex = dark ? 0xC0A98D : 0x7A5C42
        case (.pottery, .stroke): hex = dark ? 0x3E2E1F : 0xDFCBB0
        case (.pottery, .primary): hex = dark ? 0xE0A070 : 0x8F3A1F
        case (.pottery, .onPrimary): hex = dark ? 0x1A1109 : 0xFFFAF1
        case (.pottery, .keyboard): hex = dark ? 0x161009 : 0xECDCC6
        case (.pottery, .key): hex = dark ? 0x2A1E13 : 0xFFFAF1
        case (.pottery, .pressed): hex = dark ? 0x46331F : 0xCFB896
        case (.pottery, .utility): hex = dark ? 0x20170F : 0xDECBAF
        case (.pottery, .shadow): hex = dark ? 0x070402 : 0xA98C68
        case (.bronze, .background): hex = dark ? 0x0C1512 : 0xF0F3F0
        case (.bronze, .card): hex = dark ? 0x14201B : 0xFBFDFA
        case (.bronze, .soft): hex = dark ? 0x1C2B24 : 0xE2E9E1
        case (.bronze, .ink): hex = dark ? 0xE6F0E9 : 0x1C2A24
        case (.bronze, .muted): hex = dark ? 0x9DB5A6 : 0x52685C
        case (.bronze, .stroke): hex = dark ? 0x27392F : 0xC8D6CC
        case (.bronze, .primary): hex = dark ? 0xC9A227 : 0x2E5A44
        case (.bronze, .onPrimary): hex = dark ? 0x0C1512 : 0xFFFFFF
        case (.bronze, .keyboard): hex = dark ? 0x0F1A15 : 0xDDE7DF
        case (.bronze, .key): hex = dark ? 0x1E2C25 : 0xFBFDFA
        case (.bronze, .pressed): hex = dark ? 0x34473C : 0xB5C9B9
        case (.bronze, .utility): hex = dark ? 0x16211B : 0xC8D8CC
        case (.bronze, .shadow): hex = dark ? 0x030706 : 0x8FA495
        case (.porcelain, .background): hex = dark ? 0x0A0F1A : 0xF4F6FA
        case (.porcelain, .card): hex = dark ? 0x121927 : 0xFFFFFF
        case (.porcelain, .soft): hex = dark ? 0x1A2334 : 0xE6ECF5
        case (.porcelain, .ink): hex = dark ? 0xE8EEF9 : 0x16223A
        case (.porcelain, .muted): hex = dark ? 0x9BAAC2 : 0x4E5F7E
        case (.porcelain, .stroke): hex = dark ? 0x253145 : 0xCFD8E8
        case (.porcelain, .primary): hex = dark ? 0x6FA8FF : 0x1A4590
        case (.porcelain, .onPrimary): hex = dark ? 0x0A0F1A : 0xFFFFFF
        case (.porcelain, .keyboard): hex = dark ? 0x0C121C : 0xDFE7F3
        case (.porcelain, .key): hex = dark ? 0x1C2536 : 0xFFFFFF
        case (.porcelain, .pressed): hex = dark ? 0x2F3D55 : 0xBCCBE3
        case (.porcelain, .utility): hex = dark ? 0x131A26 : 0xCBD8EC
        case (.porcelain, .shadow): hex = dark ? 0x03050A : 0x93A5C0
        case (.japanese, .background): hex = dark ? 0x14120F : 0xF7F4EE
        case (.japanese, .card): hex = dark ? 0x1D1A16 : 0xFFFDF8
        case (.japanese, .soft): hex = dark ? 0x26221C : 0xECE6DB
        case (.japanese, .ink): hex = dark ? 0xF2EDE4 : 0x2A2622
        case (.japanese, .muted): hex = dark ? 0xB5AB9B : 0x6E665C
        case (.japanese, .stroke): hex = dark ? 0x363028 : 0xDCD3C4
        case (.japanese, .primary): hex = dark ? 0xE8A0A4 : 0x8F2A31
        case (.japanese, .onPrimary): hex = dark ? 0x14120F : 0xFFFDF8
        case (.japanese, .keyboard): hex = dark ? 0x110F0C : 0xE9E3D7
        case (.japanese, .key): hex = dark ? 0x251F19 : 0xFFFDF8
        case (.japanese, .pressed): hex = dark ? 0x40382E : 0xD0C4B0
        case (.japanese, .utility): hex = dark ? 0x1A1712 : 0xDCD2C2
        case (.japanese, .shadow): hex = dark ? 0x050403 : 0xA89A85
        case (.cyberpunk, .background): hex = dark ? 0x05060A : 0xF2F5FA
        case (.cyberpunk, .card): hex = dark ? 0x0C0F18 : 0xFFFFFF
        case (.cyberpunk, .soft): hex = dark ? 0x141926 : 0xE4EAF4
        case (.cyberpunk, .ink): hex = dark ? 0xEAF2FF : 0x101828
        case (.cyberpunk, .muted): hex = dark ? 0x8FA6C9 : 0x4C5A75
        case (.cyberpunk, .stroke): hex = dark ? 0x1E2740 : 0xC9D3E6
        case (.cyberpunk, .primary): hex = dark ? 0x00F0FF : 0x0B63CE
        case (.cyberpunk, .onPrimary): hex = dark ? 0x05060A : 0xFFFFFF
        case (.cyberpunk, .keyboard): hex = dark ? 0x070910 : 0xDCE4F2
        case (.cyberpunk, .key): hex = dark ? 0x141A28 : 0xFFFFFF
        case (.cyberpunk, .pressed): hex = dark ? 0x26314A : 0xB7C4DC
        case (.cyberpunk, .utility): hex = dark ? 0x0E121C : 0xC7D3E8
        case (.cyberpunk, .shadow): hex = dark ? 0x000000 : 0x8F9FB8
        case (.gothic, .background): hex = dark ? 0x08050A : 0xF4F1F2
        case (.gothic, .card): hex = dark ? 0x110B12 : 0xFFFFFF
        case (.gothic, .soft): hex = dark ? 0x1A1219 : 0xE8E2E5
        case (.gothic, .ink): hex = dark ? 0xF2E7EE : 0x1A1013
        case (.gothic, .muted): hex = dark ? 0xA8929F : 0x5E4E55
        case (.gothic, .stroke): hex = dark ? 0x2A1C26 : 0xD4C7CD
        case (.gothic, .primary): hex = dark ? 0xB3123F : 0x5E1823
        case (.gothic, .onPrimary): hex = dark ? 0xFFFFFF : 0xFFFFFF
        case (.gothic, .keyboard): hex = dark ? 0x0A070C : 0xE4DCE0
        case (.gothic, .key): hex = dark ? 0x1D141C : 0xFFFFFF
        case (.gothic, .pressed): hex = dark ? 0x35252F : 0xC3B4BB
        case (.gothic, .utility): hex = dark ? 0x120C13 : 0xD3C6CC
        case (.gothic, .shadow): hex = dark ? 0x000000 : 0xA08D95
        case (.mecha, .background): hex = dark ? 0x0D0F11 : 0xEEF0F1
        case (.mecha, .card): hex = dark ? 0x15191C : 0xF9FAFA
        case (.mecha, .soft): hex = dark ? 0x1E2327 : 0xDEE2E4
        case (.mecha, .ink): hex = dark ? 0xE8EDF0 : 0x14181A
        case (.mecha, .muted): hex = dark ? 0x9AA4AB : 0x4E575C
        case (.mecha, .stroke): hex = dark ? 0x2A3136 : 0xC4CBD0
        case (.mecha, .primary): hex = dark ? 0xFFC400 : 0xA85400
        case (.mecha, .onPrimary): hex = dark ? 0x0D0F11 : 0xFFFFFF
        case (.mecha, .keyboard): hex = dark ? 0x101315 : 0xD8DDE0
        case (.mecha, .key): hex = dark ? 0x20262A : 0xF9FAFA
        case (.mecha, .pressed): hex = dark ? 0x394146 : 0xAEB6BC
        case (.mecha, .utility): hex = dark ? 0x171C1F : 0xC6CDD2
        case (.mecha, .shadow): hex = dark ? 0x000000 : 0x8B959B
        }
        return UIColor(red: CGFloat((hex >> 16) & 255)/255,
                       green: CGFloat((hex >> 8) & 255)/255,
                       blue: CGFloat(hex & 255)/255,
                       alpha: 1)
    }
}
