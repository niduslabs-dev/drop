import AppKit
import SwiftUI

/// How a panel board is presented: the popup's floating card, or the content of the
/// centred window an opened disk image gets.
enum PanelPresentation {
    case popup
    case window
}

extension EnvironmentValues {
    @Entry var panelPresentation = PanelPresentation.popup
    /// The centred window's title bar height, read from the window.
    @Entry var titleBarHeight: CGFloat = 0
    /// Cards at the popup's 400 pt scale (radius 10, padding 12) or window scale (radius 14,
    /// padding 12 × 16), per the guide's InfoCard.
    @Entry var cardScale = CardScale.panel
}

enum CardScale {
    case panel
    case window

    var cornerRadius: CGFloat { self == .panel ? Theme.Card.cornerRadius : Theme.Radius.card }
    var horizontalPadding: CGFloat { self == .panel ? Theme.Card.horizontalPadding : Theme.Space.l }
}

/// The card every panel board sits in. As a popup: rounded, the surface at 92% over the
/// popover material, a hairline border. In the centred window the window is the card, so
/// only the insets remain, the top one below the title bar.
struct PanelCard<Content: View>: View {
    var spacing: CGFloat = Theme.Panel.spacing
    @ViewBuilder var content: Content
    @Environment(\.panelPresentation) private var presentation
    @Environment(\.titleBarHeight) private var titleBarHeight

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Panel.cornerRadius, style: .continuous)
        let stack = VStack(alignment: .leading, spacing: spacing) { content }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Colour.bodyText)
        switch presentation {
        case .popup:
            stack
                .padding(Theme.panelInset)
                .frame(width: Theme.Panel.width, alignment: .leading)
                .background { SurfaceBackground(kind: .popup).clipShape(shape) }
                .overlay { shape.strokeBorder(Theme.Colour.hairline) }
        case .window:
            stack
                .padding(.top, titleBarHeight + Theme.CentredWindow.titleGap)
                .padding([.horizontal, .bottom], Theme.panelInset)
                .frame(width: Theme.Panel.width, alignment: .leading)
                .background(SurfaceBackground(kind: .window))
        }
    }
}

/// A window's backdrop. Light: the white surface, over the popover material for the popup.
/// Dark: the ink glass (`Theme.Glass`), or solid ink with Reduce Transparency.
struct SurfaceBackground: View {
    enum Kind {
        case popup
        case window
        case settings
    }
    let kind: Kind
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if colorScheme == .dark {
            if reduceTransparency {
                kind == .popup ? Theme.Glass.solidPanel : Theme.Glass.solidWindow
            } else {
                ZStack {
                    VisualEffectBackground(material: Theme.Glass.darkMaterial)
                    if kind == .settings {
                        Theme.Glass.settingsTint.opacity(Theme.Glass.settingsTintOpacity)
                    } else {
                        Theme.Glass.panelTint.opacity(Theme.Glass.panelTintOpacity)
                    }
                }
            }
        } else {
            switch kind {
            case .popup:
                ZStack {
                    VisualEffectBackground(material: Theme.Glass.lightPopupMaterial)
                    Theme.Colour.surface.opacity(Theme.Panel.surfaceOpacity)
                }
            case .window: Theme.Colour.surface
            case .settings: Color(nsColor: .windowBackgroundColor)
            }
        }
    }
}

/// An always-active behind-window material, so the backdrop doesn't dim while Drop is in
/// the background (the popup never takes focus).
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// "Drop · New in Downloads · Linea-2.4.1.dmg", with the drop glyph: every popup says
/// who's asking in its top line.
struct ImageHeader: View {
    let model: PanelModel

    var body: some View {
        HStack(spacing: Theme.Header.spacing) {
            Image(systemName: "drop")
                .font(.system(size: Theme.Header.glyph, weight: .semibold))
                .foregroundStyle(Theme.Colour.link)
            (Text("Drop").font(Theme.Font.captionStrong).foregroundStyle(Theme.Colour.bodyText)
                + Text(" \u{00B7} \(detail)").foregroundStyle(Theme.Colour.secondaryText))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.Font.caption)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch model.origin {
        case .watched(let folder): "New in \(folder) \u{00B7} \(model.dmg.lastPathComponent)"
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
                    .fill(Theme.Colour.placeholderTile.opacity(Theme.Icon.placeholderFillOpacity))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.Colour.separator)
                    }
                    .overlay {
                        Image(systemName: symbol).font(
                            .system(size: glyph * Theme.Icon.placeholderGlyphScale, weight: .regular)
                        )
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
    var subtitleSpacing: CGFloat = Theme.Panel.titleSpacing
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
        titleFont: Font = Theme.Font.title, subtitleSpacing: CGFloat = Theme.Panel.titleSpacing,
        @ViewBuilder subtitle: () -> Subtitle
    ) {
        self.init(
            icon: icon, title: title, iconSize: iconSize, iconCornerRadius: iconCornerRadius, iconGlyph: iconGlyph,
            titleFont: titleFont, subtitleSpacing: subtitleSpacing, subtitle: subtitle, badge: { EmptyView() })
    }
}

/// The kit's info card: neutral by default, or warn or error.
struct InfoCard<Content: View>: View {
    var kind = CardKind.ok
    var spacing: CGFloat = Theme.Card.rowSpacing
    @ViewBuilder var content: Content
    @Environment(\.cardScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: scale.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) { content }
            .font(Theme.Font.small)
            .foregroundStyle(kind.text)
            .padding(.vertical, Theme.Card.verticalPadding)
            .padding(.horizontal, scale.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.fill, in: shape)
            .overlay { shape.strokeBorder(Theme.Colour.hairline, lineWidth: Theme.Radius.cardHairline) }
    }
}

/// A window-scale card (r14, 0.5 hairline, no shadow) holding SettingsRows: the install
/// window's options and every Settings group.
struct RowCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(Theme.Colour.hairline).frame(height: Theme.Radius.cardHairline)
                            .padding(.horizontal, Theme.Row.dividerInset)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.Colour.infoFill, in: shape)
        .overlay { shape.strokeBorder(Theme.Colour.hairline, lineWidth: Theme.Radius.cardHairline) }
    }
}

/// The SettingsRow primitive: a title (with an optional ⓘ and one caption line) on the
/// left and one control on the right, padded 16 × 12.
struct SettingsRow<Control: View, Info: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var info: Info
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Theme.Row.labelControlGap) {
            VStack(alignment: .leading, spacing: Theme.Row.captionGap) {
                HStack(spacing: Theme.Row.titleInfoGap) {
                    Text(title).font(Theme.Font.body).foregroundStyle(Theme.Colour.bodyText)
                    info
                }
                if let caption {
                    Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, Theme.Row.horizontalPadding)
        .padding(.vertical, Theme.Row.verticalPadding)
    }
}

extension SettingsRow where Info == EmptyView {
    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: title, caption: caption, info: { EmptyView() }, control: control)
    }
}

/// A switch as a whole SettingsRow: the row toggles on click, Space toggles it when
/// focused, and VoiceOver reads it as one switch.
struct SwitchRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(Theme.Font.body).foregroundStyle(Theme.Colour.bodyText)
            if let caption {
                Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.Colour.secondaryText).lineLimit(1)
            }
        }
        .toggleStyle(.nidusSwitch)
        .padding(.horizontal, Theme.Row.horizontalPadding)
        .padding(.vertical, Theme.Row.verticalPadding)
    }
}

struct CardRow: View {
    let symbol: String
    var colour: Color = Theme.Colour.secondaryText
    let text: Text

    var body: some View {
        HStack(spacing: Theme.Card.iconSpacing) {
            Image(systemName: symbol)
                .font(.system(size: Theme.Card.rowGlyph, weight: .semibold))
                .foregroundStyle(colour)
                .frame(width: Theme.Card.rowIcon, height: Theme.Card.rowIcon)
            text
        }
        .accessibilityElement(children: .combine)
    }
}

/// A warn or error card with an icon, an optional bold title and a message: Warning,
/// Update's running-app notice, Refused.
struct Callout: View {
    var kind = CardKind.warn
    var symbol = "exclamationmark.triangle"
    var title: String?
    let message: String

    var body: some View {
        InfoCard(kind: kind) {
            HStack(alignment: .top, spacing: Theme.Card.calloutSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Card.calloutGlyph, weight: .semibold))
                    .foregroundStyle(kind.icon)
                    .frame(width: Theme.Card.calloutIcon, height: Theme.Card.calloutIcon)
                VStack(alignment: .leading, spacing: Theme.Card.calloutLineSpacing) {
                    if let title { Text(title).font(Theme.Font.calloutTitle).foregroundStyle(kind.title) }
                    Text(message).font(Theme.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
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
