import AppKit
import SwiftUI

// The kit's in-row update pieces (UpdatesInRow board), shared with Pane's `Kit/` like
// Controls.swift and Motion.swift: the version row, the What's new sheet, the bundled
// release-notes reader and the VoiceOver announcement. Nothing here knows Sparkle or an app's
// model: each app maps its own update state to an `UpdateRowContent` and its notes to
// `ReleaseNoteGroup`s.

/// Everything the version row draws in one state: the title, the line under it (with an
/// optional spinner or rolling percentage), the row's capsule and What's new.
struct UpdateRowContent: Equatable {
    enum Lead: Equatable {
        case none
        /// The kit's mini spinner leads the line (checking, preparing, installing).
        case spinner
    }

    enum ButtonKind: Equatable {
        case primary
        case secondary
    }

    /// "Version 1.0.5".
    var title: String
    /// The line under the title, without the percentage.
    var caption: String
    /// A shorter line for when `caption` doesn't fit beside the capsules ("checked yesterday"
    /// for "checked yesterday at 12:40 PM").
    var shortCaption: String?
    /// The download percentage after the line (" · 42%"), rolling as it changes.
    var percent: Int?
    var lead = Lead.none
    /// The line is a failure: the error colour.
    var isError = false
    /// The capsule's label; one capsule whose label changes in place.
    var button: String
    var buttonKind = ButtonKind.secondary
    var buttonEnabled = true
    /// What VoiceOver calls the capsule ("Restart to update to Drop 1.0.6").
    var buttonAccessibilityLabel: String
    /// What's new is left out in builds that can't update.
    var showsWhatsNew = true
    /// "What's new in Drop 1.0.5".
    var whatsNewAccessibilityLabel: String

    /// The line as VoiceOver reads and announces it: middle dots read as commas, the
    /// percentage left out (it would be announced on every step).
    var spokenCaption: String {
        caption.replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }
}

/// The SettingsRow primitive with two small capsules (UpdatesInRow board): the title and its
/// line on the left; What's new and the row's action on the right. The line blur-swaps when
/// it changes, the action relabels in place, and the percentage rolls (`RollingNumber`).
/// When the action dims while it has keyboard focus, focus moves to What's new, which never
/// dims. Each new line is announced to VoiceOver once.
struct UpdateRow: View {
    let content: UpdateRowContent
    let action: () -> Void
    let whatsNew: () -> Void
    /// Focus for What's new: the row moves it there, and the app returns it there when the
    /// sheet closes.
    let whatsNewFocus: FocusLink
    @State private var actionFocus = FocusLink()

    var body: some View {
        HStack(spacing: Theme.Row.labelControlGap) {
            VStack(alignment: .leading, spacing: Theme.Row.captionGap) {
                Text(content.title).font(Theme.Font.body).foregroundStyle(Theme.Colour.bodyText)
                StatusSwap(key: content.caption) { line }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(content.title), \(content.spokenCaption)")
            .accessibilityValue(content.percent.map { "\($0)%" } ?? "")
            // The left side fills the row instead of a Spacer, which would add a second
            // label-to-control gap: the idle line ("Up to date · checked today at 9:12 AM") is
            // the longest and only just fits beside two capsules.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: Theme.UpdateRow.buttonGap) {
                if content.showsWhatsNew {
                    Button("What's new", action: whatsNew)
                        .buttonStyle(NidusButtonStyle(kind: .secondary, size: .small, focusLink: whatsNewFocus))
                        .accessibilityLabel(content.whatsNewAccessibilityLabel)
                }
                Button(action: action) { SwapLabel(title: content.button) }
                    .buttonStyle(
                        NidusButtonStyle(
                            kind: content.buttonKind == .primary ? .primary : .secondary, size: .small,
                            focusLink: actionFocus)
                    )
                    .disabled(!content.buttonEnabled)
                    .accessibilityLabel(content.buttonAccessibilityLabel)
            }
        }
        .padding(.horizontal, Theme.Row.horizontalPadding)
        .padding(.vertical, Theme.Row.verticalPadding)
        .onChange(of: content.buttonEnabled) { _, enabled in
            guard !enabled, actionFocus.isFocused else { return }
            actionFocus.isFocused = false
            if content.showsWhatsNew { whatsNewFocus.request() }
        }
        .onChange(of: content.caption) { _, _ in StatusAnnouncer.announce(content.spokenCaption) }
    }

    @ViewBuilder private var line: some View {
        if let short = content.shortCaption {
            ViewThatFits(in: .horizontal) {
                line(content.caption)
                line(short)
            }
        } else {
            line(content.caption)
        }
    }

    private func line(_ caption: String) -> some View {
        HStack(spacing: Theme.UpdateRow.spinnerGap) {
            if content.lead == .spinner {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                Text(caption)
                if let percent = content.percent {
                    Text(" \u{00B7} ")
                    RollingNumber("\(percent)%", value: Double(percent))
                }
            }
            .lineLimit(1)
            .monospacedDigit()
        }
        .font(Theme.Font.caption)
        .foregroundStyle(content.isError ? Theme.Colour.error : Theme.Colour.secondaryText)
    }
}

/// Posts a VoiceOver announcement. Status lines that change without focus moving (the
/// version row) say each new state once this way.
@MainActor
enum StatusAnnouncer {
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - Release notes

/// One version in What's new: its lines, and a tag ("Installed", "Ready to install").
struct ReleaseNoteGroup: Equatable, Identifiable {
    let version: String
    let tag: String?
    let lines: [String]
    var id: String { version }
}

/// The app's RELEASE_NOTES.md, bundled at build time: "## X.Y.Z" sections of "- " lines,
/// newest first. Anything else (the intro, blank lines) is skipped.
enum ReleaseNotesFile {
    struct Section: Equatable {
        let version: String
        let lines: [String]
    }

    static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        var version: String?
        var lines: [String] = []
        func close() {
            if let version { sections.append(Section(version: version, lines: lines)) }
            lines = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                close()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if version != nil, let marker = line.first, "-*".contains(marker), line.dropFirst().first == " " {
                lines.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        close()
        return sections
    }

    /// The bundled copy's sections; empty when the app has none (`swift run`, tests).
    static func bundled(_ bundle: Bundle = .main) -> [Section] {
        guard let url = bundle.url(forResource: "RELEASE_NOTES", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return parse(text)
    }

    /// Dotted versions compared by number ("1.0.10" is newer than "1.0.9"); a missing part
    /// counts as 0.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The Sheet primitive's list state (UpdatesInRow board): "What's new in Drop", every
/// version newest first in one scrolling card, All release notes and Done. On open, focus
/// goes to the list, so the arrow and Page keys scroll it. Return is Done, Esc closes; the
/// presenter returns focus to What's new. Tab goes list, All release notes, Done.
struct ReleaseNotesSheet: View {
    let appName: String
    let groups: [ReleaseNoteGroup]
    let allNotesURL: URL
    let openURL: (URL) -> Void
    let done: () -> Void

    @FocusState private var listFocused: Bool
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's new in \(appName)")
                .font(Theme.Font.title).tracking(Theme.Font.titleTracking)
                .foregroundStyle(Theme.Colour.bodyText)
                .accessibilityAddTraits(.isHeader)
            Text("Newest first.").font(Theme.Font.body).foregroundStyle(Theme.Colour.secondaryText)
                .padding(.top, Theme.Sheet.descriptionGap)
            if groups.isEmpty {
                card {
                    Text("No release notes for this version.").font(Theme.Font.body)
                        .foregroundStyle(Theme.Colour.secondaryText)
                        .padding(.horizontal, Theme.Sheet.groupHorizontalPadding)
                        .padding(.vertical, Theme.Sheet.groupVerticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, Theme.Sheet.bodyGap)
                Spacer(minLength: Theme.Sheet.footerGap)
            } else {
                list.padding(.top, Theme.Sheet.bodyGap)
                    .padding(.bottom, Theme.Sheet.footerGap)
            }
            HStack {
                Button("All release notes") { openURL(allNotesURL) }.buttonStyle(.nidusLink())
                Spacer(minLength: 0)
                Button("Done", action: done).buttonStyle(.nidusPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Sheet.inset)
        .frame(width: Theme.Sheet.width, height: Theme.Sheet.height, alignment: .topLeading)
        .onExitCommand(perform: done)
        .onAppear { if !groups.isEmpty { listFocused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return content()
            .background(Theme.Colour.infoFill, in: shape)
            .overlay { Hairline(shape: shape) }
    }

    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle().fill(Theme.Colour.hairline).frame(height: Theme.Radius.cardHairline)
                    }
                    groupView(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.y, $0.containerSize.height, $0.contentSize.height]
        } action: { _, value in
            offset = value[0]
            viewport = value[1]
            contentHeight = value[2]
        }
        .clipShape(shape)
        .background(Theme.Colour.infoFill, in: shape)
        .overlay { Hairline(shape: shape) }
        .modifier(FocusRing(isFocused: listFocused, shape: shape))
        .focusable(interactions: .edit)
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end]) { press in
            scrollBy(press.key)
            return .handled
        }
        .accessibilityLabel("Release notes")
    }

    private func groupView(_ group: ReleaseNoteGroup) -> some View {
        VStack(alignment: .leading, spacing: Theme.Sheet.versionToLines) {
            HStack(spacing: Theme.Sheet.tagGap) {
                Text(group.version).font(Theme.Font.calloutTitle).foregroundStyle(Theme.Colour.bodyText)
                if let tag = group.tag {
                    let pill = Capsule(style: .continuous)
                    Text(tag).font(Theme.Font.groupLabel).foregroundStyle(Theme.Colour.secondaryText)
                        .padding(.horizontal, Theme.Sheet.tagHorizontalPadding)
                        .padding(.vertical, Theme.Sheet.tagVerticalPadding)
                        .overlay { Hairline(shape: pill) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Sheet.lineGap) {
                ForEach(Array(group.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\u{2022}").frame(width: Theme.Sheet.bulletIndent, alignment: .leading)
                            .accessibilityHidden(true)
                        Text(line).lineSpacing(Theme.Sheet.noteLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Colour.bodyText)
        }
        .padding(.horizontal, Theme.Sheet.groupHorizontalPadding)
        .padding(.vertical, Theme.Sheet.groupVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The list's keyboard scrolling while it has focus.
    private func scrollBy(_ key: KeyEquivalent) {
        let page = max(viewport - Theme.Sheet.pageOverlap, Theme.Sheet.arrowScroll)
        let maxOffset = max(contentHeight - viewport, 0)
        let target: CGFloat
        switch key {
        case .upArrow: target = offset - Theme.Sheet.arrowScroll
        case .downArrow: target = offset + Theme.Sheet.arrowScroll
        case .pageUp: target = offset - page
        case .pageDown: target = offset + page
        case .home: target = 0
        default: target = maxOffset
        }
        withAnimation(Theme.Motion.fade) { scroll.scrollTo(y: min(max(target, 0), maxOffset)) }
    }
}
