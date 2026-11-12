import DMCNKit
import SwiftUI
import UIKit

/// The main column in the mail section: the list for the chosen view, or the open message.
struct MailColumn: View {
    let session: MailSession

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let open = session.openMessage {
                MessageReader(session: session, reader: open)
                    .id(open.id)
                    .transition(.move(edge: .trailing))
            } else if session.folder == .drafts {
                DraftList(session: session)
            } else {
                MailList(session: session)
            }
            if session.openMessage == nil {
                Button {
                    session.compose()
                } label: {
                    Icon.pencil.image(22)
                        .foregroundStyle(.textOnBrand)
                        .frame(width: 56, height: 56)
                        .background(.brand, in: .dsCard)
                        .dsShadow()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Compose")
                .padding(Space.s5)
            }
        }
        .animation(Motion.normal, value: session.openMessage?.id)
    }
}

struct MailList: View {
    let session: MailSession
    /// The row whose ⋮ swipe button opened the full folder list.
    @State private var pickingFolderFor: MailRow?
    /// What was picked there (nil folder: the Inbox), filed once the sheet is gone so the follow-up
    /// question can show.
    @State private var picked: (row: MailRow, folderID: String?)?
    /// The row whose filing tray is open, if any.
    @State private var openFilingRow: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                PageTitle(title: session.folderTitle, count: session.isLocked ? nil : session.rowCountText)
                Spacer(minLength: 0)
                DSIconButton(.refresh, label: "Refresh", size: .sm) { Task { await session.refresh() } }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }

            if session.folder == .deleted {
                listNote(session.deletedNote)
            }
            if let progress = session.searchProgressNote {
                listNote(progress)
            }

            List {
                if let error = session.listError {
                    Text(error)
                        .dsFont(.sm)
                        .foregroundStyle(.danger)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.dangerSubtle, in: .dsCard)
                        .padding(Space.s4)
                        .plainRow()
                }
                if session.isSorting {
                    EmptyView()
                } else if session.rows.isEmpty {
                    if !session.isLocked {
                        EmptyState(icon: session.emptyIcon.designIcon, text: session.emptyText).plainRow()
                    }
                } else {
                    ForEach(session.rows) { row in
                        filingSwipe(row) {
                            MailRowView(row: row, caution: session.filedByAddressOnly(row))
                                .contentShape(Rectangle())
                                .onTapGesture { session.open(row) }
                        }
                        .plainRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipeButtons(row) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.surfacePage)
            .refreshable { await session.refresh() }
            .modifier(ClosesFilingTrayOnScroll(openID: $openFilingRow))
        }
        .sheet(
            item: $pickingFolderFor,
            onDismiss: {
                if let choice = picked {
                    picked = nil
                    session.file(choice.row, in: choice.folderID)
                }
            }
        ) { row in
            FolderPicker(
                includeInbox: session.folder != .inbox,
                folders: session.folders.filter { MailFolder.folder($0.id) != session.folder }
            ) { id in
                picked = (row, id)
                pickingFolderFor = nil
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            session.filingOffer?.title ?? "",
            isPresented: Binding(
                get: { session.filingOffer != nil },
                set: { if !$0 { session.declineFilingOffer() } }),
            titleVisibility: .visible,
            presenting: session.filingOffer
        ) { offer in
            Button(offer.answer) {
                Task { await session.acceptFilingOffer(offer) }
            }
            // Not .cancel: a popover dialog hides its cancel button, and this answer should be seen.
            Button("Just this one") { session.declineFilingOffer() }
        } message: { offer in
            Text(offer.summary)
        }
    }

    /// A right swipe files the row: one button per folder slot, then ⋮ for every other folder and
    /// the Inbox. The folder already being shown is left out, since filing there would do nothing.
    @ViewBuilder private func filingSwipe(_ row: MailRow, @ViewBuilder content: () -> some View) -> some View {
        let folders = session.swipeFolders.filter { MailFolder.folder($0.id) != session.folder }
        if !session.canSwipeToFile || row.isSent || row.inDeleted {
            content()
        } else if #available(iOS 18, *) {
            FilingSwipeRow(
                id: row.id,
                folders: folders,
                openID: $openFilingRow,
                file: { session.file(row, in: $0) },
                more: { pickingFolderFor = row }
            ) {
                content()
            }
        } else {
            // iOS 17 can't hand a drag back to the list, so it gets the system's swipe. Its buttons
            // are wide, so only two folders fit beside ⋮.
            content()
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    fileButtons(row, folders: Array(folders.prefix(2)))
                }
        }
    }

    @ViewBuilder private func fileButtons(_ row: MailRow, folders: [FolderDef]) -> some View {
        ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
            Button {
                session.file(row, in: folder.id)
            } label: {
                Label {
                    Text(folder.name)
                } icon: {
                    Icon.folder.image(20)
                }
            }
            .tint(FilingSwipeColors.color(index))
        }
        Button {
            pickingFolderFor = row
        } label: {
            Label {
                Text("More folders")
            } icon: {
                Icon.moreVertical.image(20)
            }
        }
        .tint(.textMuted)
    }

    private func listNote(_ text: String) -> some View {
        Text(text)
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }

    /// Deleted mail offers Restore and a permanent delete; everything else, Archive and Delete.
    @ViewBuilder private func swipeButtons(_ row: MailRow) -> some View {
        if row.inDeleted {
            Button(role: .destructive) {
                session.deleteForever(row)
            } label: {
                Label {
                    Text("Delete forever")
                } icon: {
                    Icon.trash.image(20)
                }
            }
            .tint(.danger)
            Button {
                session.restore(row)
            } label: {
                Label {
                    Text("Restore")
                } icon: {
                    Icon.undo.image(20)
                }
            }
            .tint(.textMuted)
        } else {
            Button(role: .destructive) {
                session.trash(row)
            } label: {
                Label {
                    Text("Delete")
                } icon: {
                    Icon.trash.image(20)
                }
            }
            .tint(.danger)
            if !row.isSent {
                Button {
                    session.toggleArchive(row)
                } label: {
                    Label {
                        Text(row.inArchive ? "Unarchive" : "Archive")
                    } icon: {
                        Icon.archive.image(20)
                    }
                }
                .tint(.textMuted)
            }
        }
    }
}

/// A right swipe that files the row: up to four folder buttons and a half-width ⋮ for everything
/// else, sized together to fit the row. Built by hand because the system's swipe buttons are a fixed
/// width, so five don't fit a phone. Left swipes are still the system's own actions.
@available(iOS 18, *)
private struct FilingSwipeRow<Content: View>: View {
    let id: String
    let folders: [FolderDef]
    /// The one row whose tray is open, shared by the list so opening one closes the rest.
    @Binding var openID: String?
    let file: (String) -> Void
    let more: () -> Void
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 0

    private var isOpen: Bool { openID == id }
    /// One folder button's width. ⋮ takes half of one. Together they leave a sliver of the row
    /// showing, so it's clear what is being filed.
    private var unit: CGFloat {
        guard width > 0 else { return 76 }
        return min(84, max(56, width * 0.86 / (CGFloat(folders.count) + 0.5)))
    }
    private var reveal: CGFloat { unit * (CGFloat(folders.count) + 0.5) }
    private var offset: CGFloat {
        let raw = (isOpen ? reveal : 0) + drag
        // Past the end the row resists, the way the system's swipe does.
        return raw > reveal ? reveal + (raw - reveal) * 0.25 : max(0, raw)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if offset > 0 { tray }
            content
                .overlay {
                    // While open, a tap on the row closes the tray instead of opening the message.
                    // Laid on before the offset so it slides with the row and leaves the tray's
                    // buttons uncovered.
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offset)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .gesture(FilingPan(takesLeftward: isOpen, moved: dragged, released: released))
        .sensoryFeedback(.selection, trigger: offset >= reveal)
        .accessibilityActions {
            ForEach(folders, id: \.id) { folder in
                Button("Move to \(folder.name)") { file(folder.id) }
            }
            Button("More folders") { more() }
        }
    }

    private var tray: some View {
        HStack(spacing: 0) {
            ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                trayButton(color: FilingSwipeColors.color(index), width: unit) {
                    file(folder.id)
                } label: {
                    VStack(spacing: 4) {
                        Icon.folder.image(18)
                        Text(folder.name).dsFont(.xxs, .semibold).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 4)
                }
            }
            trayButton(color: .textMuted, width: unit / 2) {
                more()
            } label: {
                Icon.moreVertical.image(18)
            }
            .accessibilityLabel("More folders")
        }
        .frame(width: reveal, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    private func trayButton(
        color: Color, width: CGFloat, action: @escaping () -> Void, @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            close()
            action()
        } label: {
            label()
                .foregroundStyle(.white)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(color)
        }
        .buttonStyle(.plain)
    }

    private func dragged(_ dx: CGFloat) {
        // Starting to open this row puts away any other open tray.
        if !isOpen, openID != nil { openID = nil }
        drag = dx
    }

    /// `dx` is where the drag would coast to, so a quick flick opens or closes it too.
    private func released(_ dx: CGFloat) {
        let landing = (isOpen ? reveal : 0) + dx
        withAnimation(.snappy) {
            if landing > reveal / 2 {
                openID = id
            } else if isOpen {
                openID = nil
            }
            drag = 0
        }
    }

    private func close() {
        withAnimation(.snappy) {
            if isOpen { openID = nil }
            drag = 0
        }
    }
}

/// The filing swipe's drag. A UIKit one, because UIKit can turn a touch down the moment it starts:
/// only a sideways drag to the right (or to the left, to push an open tray shut) is taken, and the
/// rest go on to the list, so scrolling and the system's left swipe keep working. SwiftUI's own drag
/// can't hand a touch back, and the left swipe stopped working with it.
@available(iOS 18, *)
private struct FilingPan: UIGestureRecognizerRepresentable {
    let takesLeftward: Bool
    let moved: (CGFloat) -> Void
    let released: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.takesLeftward = takesLeftward
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            moved(dx)
        case .ended:
            // A short coast in the direction of travel, like SwiftUI's predicted end.
            released(dx + recognizer.velocity(in: recognizer.view).x * 0.2)
        case .cancelled, .failed:
            released(dx)
        default:
            break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var takesLeftward = false

        /// Asked once, as the touch starts to move: is this drag ours?
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            // The distance moved still reads zero here, so go by the direction the finger is heading.
            let heading = pan.velocity(in: pan.view)
            return abs(heading.x) > abs(heading.y) * 1.5 && (heading.x > 0 || takesLeftward)
        }
    }
}

/// The folder colors, shared by the custom tray and the system swipe on iOS 17.
private enum FilingSwipeColors {
    static func color(_ index: Int) -> Color {
        LabelColor.color(LabelColor.choices[(index + 3) % LabelColor.choices.count])
    }
}

/// Scrolling the list puts away an open filing tray. The scroll phase arrived in iOS 18, the same
/// as the custom tray; iOS 17 uses the system's swipe, which puts itself away.
private struct ClosesFilingTrayOnScroll: ViewModifier {
    @Binding var openID: String?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in
                if phase != .idle, openID != nil { withAnimation(.snappy) { openID = nil } }
            }
        } else {
            content
        }
    }
}

/// Every folder, for the swipe's ⋮ button, so a folder that isn't in a slot can still be reached,
/// and the Inbox, to put something back. `pick` gets nil for the Inbox.
private struct FolderPicker: View {
    let includeInbox: Bool
    let folders: [FolderDef]
    let pick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if includeInbox {
                    choice(icon: .inbox, name: "Inbox") { pick(nil) }
                }
                ForEach(folders, id: \.id) { folder in
                    choice(icon: .folder, name: folder.name) { pick(folder.id) }
                }
            }
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func choice(icon: Icon, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                icon.image(18).foregroundStyle(.textMuted)
                Text(name).dsFont(.md).foregroundStyle(.textBody)
            }
        }
    }
}

extension View {
    /// A list row with no system chrome: the row draws its own surface and rule.
    fileprivate func plainRow() -> some View {
        listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// One message in a list. Two lines and a snippet, as the web's phone layout.
struct MailRowView: View {
    let row: MailRow
    /// Filed by an address nothing checked: see `MailSession.filedByAddressOnly`.
    var caution = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s2) {
                if row.isUnread {
                    Circle().fill(.brand).frame(width: 8, height: 8).accessibilityLabel("Unread")
                }
                KindIcon(kind: row.kind, trusted: row.trustedSender).padding(.trailing, 2)
                Text(row.who)
                    .dsFont(.md, row.isUnread ? .bold : .medium)
                    .foregroundStyle(.textStrong)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let deliveredTo = row.deliveredTo {
                    Text("to \(deliveredTo)")
                        .dsMono(.xs)
                        .foregroundStyle(.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if caution {
                    Text("UNCHECKED")
                        .dsFont(.xxs, .semibold)
                        .foregroundStyle(.danger)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .background(.dangerSubtle, in: .dsCard)
                        .accessibilityLabel("Filed by address only. This sender wasn't checked.")
                } else if row.isNewSender {
                    SmallTag(text: "NEW", weight: .semibold)
                }
                if row.isStarred {
                    Icon.starFill.image(14).foregroundStyle(.warning).accessibilityLabel("Starred")
                }
                Text(row.when).dsFont(.xs).foregroundStyle(.textMuted)
            }
            HStack(spacing: Space.s2) {
                if let place = row.place { SmallTag(text: place, weight: .medium) }
                Text(row.subject)
                    .dsFont(.md)
                    .foregroundStyle(.textStrong)
                    .lineLimit(1)
            }
            if let snippet = row.snippet {
                Text(snippet).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfaceCard)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }
}

private struct SmallTag: View {
    let text: String
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .dsFont(.xxs, weight)
            .foregroundStyle(.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .background(.surfaceSunken, in: .dsCard)
            .dsBorder()
    }
}

/// Which network a person is on, in one glyph. A teal shield is a DMCN identity, a blue one a
/// contact whose key still holds, and a muted envelope legacy email, which has no encryption to
/// claim however trusted the sender. An unknown kind holds the space, so rows don't shift.
struct KindIcon: View {
    let kind: SenderKind
    var trusted = false
    var size: CGFloat = 14

    var body: some View {
        switch kind {
        case .dmcn:
            Icon.shieldCheck.image(size)
                .foregroundStyle(trusted ? Color.trustContact : .trustDMCN)
                .accessibilityHidden(false)
                .accessibilityLabel(trusted ? "Trusted contact" : "DMCN identity")
        case .legacy:
            Icon.mail.image(size)
                .foregroundStyle(.textMuted)
                .accessibilityHidden(false)
                .accessibilityLabel("Legacy email")
        case .unknown:
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// The saved drafts. Drafts aren't mail, so their folder is a list of its own.
struct DraftList: View {
    let session: MailSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                PageTitle(
                    title: "Drafts",
                    count: session.drafts.count == 1 ? "1 draft" : "\(session.drafts.count) drafts")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.drafts, id: \.id) { draft in
                        HStack(alignment: .top, spacing: Space.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                                    Text(session.draftRecipients(draft))
                                        .dsFont(.md, .medium)
                                        .foregroundStyle(.textStrong)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(session.draftWhen(draft)).dsFont(.xs).foregroundStyle(.textMuted)
                                }
                                Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                                    .dsFont(.md)
                                    .foregroundStyle(.textStrong)
                                    .lineLimit(1)
                                if !draft.snippet.isEmpty {
                                    Text(draft.snippet).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                                }
                            }
                            ConfirmTrashButton(label: "Discard draft", size: .sm) { session.discardDraft(draft) }
                        }
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s3)
                        .background(.surfaceCard)
                        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { session.openDraft(draft) }
                    }
                }
            }
            .background(.surfacePage)
        }
    }
}
