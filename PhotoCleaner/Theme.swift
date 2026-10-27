import SwiftUI

/// PhotoCleaner 设计系统（对应 DESIGN.md；OKLCH 调色板已换算 sRGB）。
/// 浅深色双模：动态颜色用 UIColor(dynamicProvider:) 实现，不引 asset catalog。
enum Theme {

    // MARK: - 颜色（OKLCH → sRGB，浅 / 深两套）

    /// 深莓红，品牌主行动。oklch(0.420 0.163 350)
    static let primary = dynamic(light: "#881159", dark: "#C64E78")
    /// 大色块背景。oklch(0.300 0.120 350)
    static let primaryDeep = dynamic(light: "#550436", dark: "#7A1B44")
    /// 浅冰蓝，小标签/辅助状态。oklch(0.880 0.060 230)
    static let accent = dynamic(light: "#B0E0F8", dark: "#2C4A5C")
    /// 页面背景（浅=纯白，深=系统黑）
    static let background = dynamic(light: "#FFFFFF", dark: "#000000")
    /// 工具面板/卡片底。oklch(0.965 0.008 350)
    static let surface = dynamic(light: "#F8F1F4", dark: "#241B20")
    /// 正文。oklch(0.220 0.025 350)，浅底对比度 ≥7:1
    static let ink = dynamic(light: "#24161C", dark: "#F2E9ED")
    /// 次要文字。oklch(0.460 0.025 350)
    static let muted = dynamic(light: "#63535A", dark: "#A89AA1")
    static let success = dynamic(light: "#007E46", dark: "#3DAF7A")
    static let danger = dynamic(light: "#BE222A", dark: "#E5585F")
    /// 警示橙（相似组/废片原因等非危险提示）
    static let warning = dynamic(light: "#B26A00", dark: "#E0A040")

    private static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // MARK: - 间距 / 圆角（8pt 基准）

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 12
        static let gridCell: CGFloat = 8
    }

    // MARK: - 组件修饰

    /// 卡片：surface 底 + 12pt 圆角，无阴影（tinted surface 代替重阴影）。
    struct Card: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(Spacing.md)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        }
    }

    /// section 标题样式：13pt 次要色，不加粗。
    struct SectionHeader: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: - 按钮修饰（触控目标 ≥44pt）

    /// 主按钮：深莓红底白字。
    struct PrimaryButton: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.primary, in: RoundedRectangle(cornerRadius: Radius.card))
                .foregroundStyle(.white)
        }
    }

    /// 次按钮：surface 底 + ink 字。
    struct SecondaryButton: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                .foregroundStyle(Theme.ink)
        }
    }

    /// 危险按钮：danger 底白字，仅用于删除，且必须带文字。
    struct DangerButton: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.danger, in: RoundedRectangle(cornerRadius: Radius.card))
                .foregroundStyle(.white)
        }
    }

    // MARK: - 状态徽标（图标+文字，不只靠颜色）

    /// 小徽标：图标 + 文字胶囊。
    struct Badge: View {
        let text: String
        var systemImage: String? = nil
        var color: Color = Theme.muted

        var body: some View {
            HStack(spacing: 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(text)
            }
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
        }
    }

    /// 空态：图标 + 标题 + 下一步说明（解释用户该做什么）。
    struct EmptyState: View {
        let systemImage: String
        let title: String
        let hint: String

        var body: some View {
            VStack(spacing: Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.muted)
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.xl)
        }
    }
}

extension View {
    func themeCard() -> some View { modifier(Theme.Card()) }
    func themeSectionHeader() -> some View { modifier(Theme.SectionHeader()) }
    /// 主按钮外观（深莓红底白字，≥44pt）
    func primaryButton() -> some View { modifier(Theme.PrimaryButton()) }
    /// 次按钮外观（surface 底）
    func secondaryButton() -> some View { modifier(Theme.SecondaryButton()) }
    /// 危险按钮外观（仅删除，必须带文字）
    func dangerButton() -> some View { modifier(Theme.DangerButton()) }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}
