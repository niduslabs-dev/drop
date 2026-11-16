import AppKit
import SwiftUI

/// The rounded, translucent card every panel board sits in.
struct PanelCard<Content: View>: View {
    var spacing: CGFloat = Theme.Panel.spacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(Theme.panelInset)
            .frame(width: Theme.Panel.width, alignment: .leading)
            .background {
                ZStack {
                    VisualEffectBackground()
                    Theme.Colour.controlBackground.opacity(Theme.Panel.tintOpacity)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colour.separator.opacity(Theme.Panel.borderOpacity))
            }
            .font(Theme.Font.body)
    }
}

/// An always-active popover material, so the panel doesn't dim while Drop is in the
/// background (it never takes focus).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// "New in Downloads · Linea-2.4.1.dmg".
struct ImageHeader: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: Theme.Header.spacing) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: Theme.Header.icon, weight: .medium))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Colour.secondaryText)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch model.origin {
        case .watched(let folder): "New in \(folder) · \(model.dmg.lastPathComponent)"
        case .opened: model.dmg.lastPathComponent
        }
    }
}

struct AppIconView: View {
    let icon: PanelIcon
    var size: CGFloat = Theme.Icon.size
    var cornerRadius: CGFloat = Theme.Icon.cornerRadius
    var glyph: CGFloat = Theme.Icon.glyph

    var body: some View {
        Group {
            switch icon {
            case .image(let image):
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            case .tile(let colour, let symbol):
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colour)
                    .overlay {
                        Image(systemName: symbol).font(.system(size: glyph, weight: .semibold))
                            .foregroundStyle(Theme.Colour.onAccent)
                    }
            case .placeholder(let symbol):
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.Colour.placeholderTile.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.Colour.separator)
                    }
                    .overlay {
                        Image(systemName: symbol).font(.system(size: glyph * 0.9, weight: .regular))
                            .foregroundStyle(Theme.Colour.secondaryText)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The icon, the title and the line under it.
struct TitleRow<Subtitle: View, Badge: View>: View {
    let icon: PanelIcon
    let title: String
    var iconSize: CGFloat = Theme.Icon.size
    var iconCornerRadius: CGFloat = Theme.Icon.cornerRadius
    var iconGlyph: CGFloat = Theme.Icon.glyph
    var titleFont: Font = Theme.Font.title
    var subtitleSpacing: CGFloat = 2
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var badge: Badge

    var body: some View {
        HStack(spacing: Theme.Icon.titleSpacing) {
            AppIconView(icon: icon, size: iconSize, cornerRadius: iconCornerRadius, glyph: iconGlyph)
                .overlay(alignment: .bottomTrailing) { badge }
            VStack(alignment: .leading, spacing: subtitleSpacing) {
                Text(title).font(titleFont).tracking(Theme.Font.titleTracking).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                subtitle.font(Theme.Font.subtitle).foregroundStyle(Theme.Colour.secondaryText)
            }
        }
    }
}

extension TitleRow where Badge == EmptyView {
    init(
        icon: PanelIcon, title: String, iconSize: CGFloat = Theme.Icon.size,
        iconCornerRadius: CGFloat = Theme.Icon.cornerRadius, iconGlyph: CGFloat = Theme.Icon.glyph,
        titleFont: Font = Theme.Font.title, subtitleSpacing: CGFloat = 2,
        @ViewBuilder subtitle: () -> Subtitle
    ) {
        self.init(
            icon: icon, title: title, iconSize: iconSize, iconCornerRadius: iconCornerRadius, iconGlyph: iconGlyph,
            titleFont: titleFont, subtitleSpacing: subtitleSpacing, subtitle: subtitle, badge: { EmptyView() })
    }
}

/// The light tinted box under the title.
struct InfoCard<Content: View>: View {
    var spacing: CGFloat = Theme.Card.rowSpacing
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .font(Theme.Font.small)
            .padding(.vertical, Theme.Card.verticalPadding)
            .padding(.horizontal, Theme.Card.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(colorScheme == .dark ? Theme.Card.darkFillOpacity : Theme.Card.fillOpacity),
                in: RoundedRectangle(cornerRadius: Theme.Card.cornerRadius, style: .continuous))
    }
}

struct CardRow: View {
    let symbol: String
    var colour: Color = Theme.Colour.secondaryText
    let text: Text

    var body: some View {
        HStack(spacing: Theme.Card.iconSpacing) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Card.rowIcon - 2, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
            text
        }
        .accessibilityElement(children: .combine)
    }
}

/// The orange (or red) box: Warning, Update's running-app notice, Refused.
struct Callout: View {
    var symbol = "exclamationmark.triangle"
    var colour: Color = Theme.Colour.warning
    var iconSize: CGFloat = Theme.Card.warningIcon
    var padding: CGFloat = Theme.Card.warningPadding
    var title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Card.calloutSpacing) {
            Image(systemName: symbol)
                .font(.system(size: iconSize - 3, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(Theme.Font.calloutTitle) }
                Text(message).font(Theme.Font.small).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(title == nil ? Theme.Colour.bodyText : Theme.Colour.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(title == nil ? Theme.Card.verticalPadding : padding)
        .padding(.horizontal, title == nil ? Theme.Card.horizontalPadding - Theme.Card.verticalPadding : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            colour.opacity(Theme.Card.warningFillOpacity),
            in: RoundedRectangle(cornerRadius: Theme.Card.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The accent-filled default button.
struct PrimaryButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = Theme.Button.primaryPadding
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .singleLineLabel()
            .font(Theme.Font.primaryButton)
            .foregroundStyle(Theme.Colour.onAccent)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: Theme.Button.height)
            .background(
                Theme.Colour.accent, in: RoundedRectangle(cornerRadius: Theme.Button.cornerRadius, style: .continuous)
            )
            .opacity(isEnabled ? (configuration.isPressed ? Theme.Button.pressedOpacity : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

/// The plain bordered button.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .singleLineLabel()
            .font(Theme.Font.button)
            .foregroundStyle(Theme.Colour.bodyText)
            .padding(.horizontal, Theme.Button.secondaryPadding)
            .frame(minHeight: Theme.Button.height)
            .background(
                Theme.Colour.controlBackground,
                in: RoundedRectangle(cornerRadius: Theme.Button.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Button.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(Theme.Button.borderOpacity))
            }
            .opacity(isEnabled ? (configuration.isPressed ? Theme.Button.pressedOpacity : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

/// Text-only buttons: "Open disk image", "Undo", "Install Anyway", "Save as PDF…".
struct LinkButtonStyle: ButtonStyle {
    var colour: Color = Theme.Colour.link
    var font: Font = Theme.Font.small

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .singleLineLabel()
            .font(font)
            .foregroundStyle(colour)
            .opacity(configuration.isPressed ? Theme.Button.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    /// A button label never wraps or truncates: the button grows to fit it, and the row
    /// around it makes room (`ButtonRow`).
    func singleLineLabel() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// The bottom row: an optional link on the left, buttons on the right. When long labels
/// (a long app name in "Open <name>", a translation) don't fit on one line, the link moves
/// above the buttons, then the buttons stack, right-aligned; a label is never squeezed.
struct ButtonRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Button.spacing) {
                leading
                Spacer(minLength: Theme.Button.spacing)
                trailing
            }
            VStack(alignment: .trailing, spacing: Theme.Button.spacing) {
                HStack {
                    leading
                    Spacer(minLength: 0)
                }
                HStack(spacing: Theme.Button.spacing) { trailing }
            }
            VStack(alignment: .trailing, spacing: Theme.Button.spacing) {
                HStack {
                    leading
                    Spacer(minLength: 0)
                }
                trailing
            }
        }
    }
}

extension ButtonRow where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}
