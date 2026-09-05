// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    /// Shown as a sheet from the start screen and as a tab inside a round.
    /// A sheet needs a way out and a tab must not have one — this is set by
    /// the caller rather than read from the environment, because a screen
    /// PUSHED inside a sheet also counts as presented, and would then offer a
    /// Done button that closed the sheet it was pushed from.
    var isModal = false
    @Environment(\.dismiss) private var dismiss
    @State private var filter: SwingSetting?
    /// Break out of the round's scope, so an older swing can be found and
    /// added to it. Without this "This round" was a dead end: the swing you
    /// wanted to add was, by definition, not in the round yet.
    @State private var showEverything = false
    enum HistorySheet: Identifiable {
        case share([URL])
        case photoPicker
        case diagnostics
        var id: String {
            switch self {
            case .share(let u): return "share:" + u.map(\.lastPathComponent).joined(separator: ",")
            case .photoPicker:  return "photo"
            case .diagnostics:  return "diagnostics"
            }
        }
    }
    @State private var sheet: HistorySheet?
    @State private var showImporter = false
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var confirmingDelete = false

    /// Inside a round this screen is "this round", not "everything ever".
    ///
    /// A hitter checking that the app is working wants the last three swings,
    /// not a scroll through every clip since the project started; and the tab
    /// is labelled "This round", so showing anything else would be a lie in the
    /// most literal sense. Outside a round it is the full history, filterable.
    private var sessionScoped: [SwingDTO] {
        guard let id = model.session?.id, !showEverything else { return model.swings }
        return model.swings.filter { $0.sessionID == id }
    }

    private var visible: [SwingDTO] {
        guard let filter else { return sessionScoped }
        return sessionScoped.filter { $0.setting == filter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessionScoped.isEmpty {
                    ContentUnavailableView {
                        Label(model.isInSession ? "No swings yet this round" : "No swings yet",
                              systemImage: "figure.baseball")
                    } description: {
                        Text(model.isInSession && !showEverything
                             ? "Arm the camera on the Capture tab and hit. Every clip is kept — including the ones that measure nothing, because those are the ones worth looking at. Older swings can be pulled into this round: switch to Every swing in the filter, open one, and add it."
                             : "Start a session, set the camera up, arm it, and hit. Clips are kept so anything that looks wrong can be re-run later.")
                    } actions: {
                        Button("Import from Photos") { sheet = .photoPicker }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle(model.isInSession && !showEverything ? "This round" : "Swings")
            // The one place ending a round is always reachable. On the capture
            // screen the control can be covered by the setup overlay, and a
            // round that cannot be finished is a round that never gets
            // collated — which is the point of having rounds at all.
            .safeAreaInset(edge: .bottom) {
                if model.isInSession {
                    Button { model.endSession() } label: {
                        Label("End round and see the summary", systemImage: "flag.checkered")
                    }
                    .buttonStyle(SlabButtonStyle(size: 15))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.black)
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.fontWeight(.bold)
                    }
                }
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) { selectButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Photos first, and it is not a preference. The
                        // document picker cannot reach the original recording:
                        // it renders slow motion down to 30fps on the way out,
                        // and a 240fps clip measured as 30fps is wrong by a
                        // factor of eight with nothing downstream able to tell.
                        Button {
                            sheet = .photoPicker
                        } label: {
                            Label("From Photos (keeps 240fps)", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("From Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(model.analysisProgress != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let urls = model.exportAll()
                        if !urls.isEmpty { sheet = .share(urls) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    // `model.swings`, not `visible`: exportAll writes every
                    // stored swing, not the filtered view, so scoping this to
                    // the round would grey out an export that would have
                    // worked.
                    .disabled(model.swings.isEmpty)
                }
                // The last import's stage-by-stage report, on request rather
                // than in the way. Present only while there is one, because a
                // permanently greyed icon reads as a broken feature — and it
                // is the ONLY copy for an import that produced no swing, which
                // is exactly the case worth reading.
                if model.lastDiagnostics != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { sheet = .diagnostics } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                        .accessibilityLabel("Last analysis report")
                    }
                }
            }
            // ONE sheet modifier — see the note in StartView. Three stacked
            // on one view is not something SwiftUI reliably honours: the later
            // ones win, the earlier ones silently do nothing, and the symptom
            // is a button that simply does not respond.
            .sheet(item: $sheet) { which in
                switch which {
                case .share(let urls):
                    ShareSheet(items: urls)
                case .photoPicker:
                    PhotoClipPicker { result in
                        switch result {
                        case .success(let url):
                            model.importCopiedClip(at: url)
                        case .failure(let error):
                            model.banner = AppModel.Banner(kind: .error,
                                                           text: error.localizedDescription)
                        }
                    }
                    .ignoresSafeArea()
                case .diagnostics:
                    DiagnosticsView(report: model.lastDiagnostics ?? "",
                                    clipURL: model.lastImportedClip)
                }
            }
            // `.movie` rather than `.video`: `.video` also matches things with
            // no video track worth reading, and every failure here costs a
            // whole analysis pass to discover.
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { model.importClip(from: url) }
                case .failure(let error):
                    model.banner = AppModel.Banner(kind: .error, text: error.localizedDescription)
                }
            }
            .overlay(alignment: .bottom) { importProgress }
            // Hosted HERE, not on RootView: both pickers live on this screen,
            // and this screen is sometimes itself a sheet over the start
            // screen — an alert hosted on the covered RootView cannot present,
            // so the long-clip prompt silently never appeared and the import
            // never started.
            .alert("That is a long clip",
                   isPresented: Binding(get: { model.longClipPrompt != nil },
                                        set: { if !$0 { model.longClipPrompt = nil } }),
                   presenting: model.longClipPrompt) { prompt in
                Button("Measure it anyway") {
                    model.longClipPrompt = nil
                    model.beginAnalysis(of: prompt.url)
                }
                Button("Cancel", role: .cancel) { model.longClipPrompt = nil }
            } message: { prompt in
                Text(prompt.message)
            }
            // NOT opened automatically any more.
            //
            // It used to be, on the argument that a report nobody looks at is
            // the same as no report. True, and it still threw a full-screen
            // sheet in front of someone whose clip had just finished — every
            // time, including the ordinary case where the swing measured fine
            // and the report says "clean run". A sheet that appears on success
            // is not evidence, it is an interruption, and the way to stop
            // being interrupted was to stop importing.
            //
            // The report is now a button in the toolbar, lit only while there
            // is one to read (see `reportButton`), and every swing that
            // produced a record carries its own report on the swing screen.
            // Nothing has become unreachable; it just waits to be asked.
        }
        // The banner, again, when this screen is a sheet.
        //
        // `RootView` hosts one as a safe-area inset, and a sheet covers it —
        // so every message this screen produces (a repeat import, a file with
        // no video in it, a failed read) was being drawn underneath the sheet
        // that caused it, which is indistinguishable from the app ignoring the
        // tap. Same reasoning as the long-clip alert two modifiers up, which
        // was moved here for exactly this.
        //
        // Only when modal: as a tab inside a round this view is NOT covering
        // RootView, and hosting a second one there would show the banner twice.
        .safeAreaInset(edge: .top, spacing: 0) {
            if isModal, let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }

    /// Import is slow — three decode passes over a 240fps clip — and it happens
    /// on a screen with nothing else moving, so without this the app looks
    /// frozen and the user picks a second file on top of the first.
    @ViewBuilder private var importProgress: some View {
        if let progress = model.analysisProgress {
            VStack(spacing: 6) {
                Text("Measuring the clip…")
                    .font(.system(size: 13, weight: .bold))
                ProgressView(value: progress).tint(Theme.yellow)
                Text("Three passes at 240 fps. A few seconds per second of footage.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
    }

    private var filterMenu: some View {
        Menu {
            if model.isInSession {
                Picker("Show", selection: $showEverything) {
                    Text("This round").tag(false)
                    Text("Every swing").tag(true)
                }
                Divider()
            }
            Button("All settings") { filter = nil }
            Divider()
            ForEach(SwingSetting.allCases) { setting in
                let count = model.swings.filter { $0.setting == setting }.count
                Button("\(setting.displayName) (\(count))") { filter = setting }
                    .disabled(count == 0)
            }
        } label: {
            Label(filter?.displayName
                  ?? (model.isInSession && showEverything ? "Every swing" : "All"),
                  systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var list: some View {
        // `selection:` on the List, not on the rows. A List only offers the
        // circles in edit mode, and only when it owns the selection set.
        List(selection: $selection) {
            ForEach(visible) { swing in
                NavigationLink {
                    SwingDetailView(swing: swing)
                } label: {
                    row(swing)
                }
            }
            .onDelete { offsets in
                // Resolve rows before deleting anything: `visible` is a
                // computed filter, so deleting inside the loop shifts every
                // later index onto the wrong swing.
                model.delete(offsets.map { visible[$0] })
            }
        }
        .environment(\.editMode, $editMode)
        // A selection that outlives the rows it named would delete whatever
        // took their place. Cleared whenever the visible set changes and
        // whenever selecting stops.
        .onChange(of: editMode) { _, mode in
            if mode == .inactive { selection.removeAll() }
        }
        .onChange(of: model.swingsRevision) { _, _ in
            selection = selection.intersection(visible.map(\.id))
        }
        .confirmationDialog("Delete \(selection.count) swing\(selection.count == 1 ? "" : "s")?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(selection.count)", role: .destructive) {
                model.delete(visible.filter { selection.contains($0.id) })
                selection.removeAll()
                editMode = .inactive
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("The clips go too. Nothing here is recoverable afterwards.")
        }
    }

    /// Select / Done, and the delete that only exists while selecting.
    ///
    /// Not `EditButton()`: that one is bound to the environment's edit mode and
    /// says "Edit", which in a list of measurements reads like it will let you
    /// change them. This screen only ever offers deleting.
    @ViewBuilder private var selectButton: some View {
        if editMode == .active {
            HStack(spacing: 14) {
                // Export before Delete, and not only for safety: sending the
                // evidence somewhere is the reason to select a run of swings
                // far more often than deleting them is.
                Button {
                    let chosen = visible.filter { selection.contains($0.id) }
                    if let url = model.exportDiagnostics(for: chosen) { sheet = .share([url]) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Text("Delete\(selection.isEmpty ? "" : " \(selection.count)")")
                }
                .disabled(selection.isEmpty)
                Button("Done") { editMode = .inactive }.fontWeight(.bold)
            }
        } else if !visible.isEmpty {
            Button("Select") { editMode = .active }
        }
    }

    private func row(_ swing: SwingDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(swing.clipFilename ?? swing.setting.rawValue)
                    .font(.headline.monospaced())
                Spacer()
                Text(swing.capturedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if swing.trackedFrames == 0 {
                Label("no track", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 16) {
                    Text(String(format: "%.1f°", swing.launchAngleDeg))
                    Text("\(model.settings.speedUnit.format(mph: swing.exitVeloMph)) \(model.settings.speedUnit.suffix)")
                    Text("\(swing.trackedFrames)f")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
                ConfidenceRow(flags: swing.flags, captureFlags: swing.captureFlags)
            }
        }
        .padding(.vertical, 2)
    }
}
