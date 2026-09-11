// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Foundation

/// Where clips, track CSVs and exports live on the device.
///
/// Everything sits under Documents with file sharing enabled, so clips can be
/// pulled off with Finder or the Files app and dropped into `spike/clips/`
/// without AirDrop in the loop.
enum ClipStore {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var clipsDirectory: URL { ensure(documents.appendingPathComponent("Clips", isDirectory: true)) }
    static var tracksDirectory: URL { ensure(documents.appendingPathComponent("Tracks", isDirectory: true)) }
    static var exportsDirectory: URL { ensure(documents.appendingPathComponent("Exports", isDirectory: true)) }

    private static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Provisional name at capture time; renamed to the protocol's
    /// `<setting>_<nn>.mov` convention once the swing is filed.
    static func newClipURL(index: Int) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return clipsDirectory.appendingPathComponent("pending_\(stamp)_\(index).mov")
    }

    static func clipURL(named name: String) -> URL {
        clipsDirectory.appendingPathComponent(name)
    }

    static func trackURL(named name: String) -> URL {
        tracksDirectory.appendingPathComponent(name)
    }

    /// Rename to `tee_01.mov`, `cage_04.mov`, ... picking the next free index
    /// for that setting — the exact convention `batch_run.py` parses.
    @discardableResult
    static func fileUnderConvention(clip: URL, setting: SwingSetting) -> String? {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: clipsDirectory.path)) ?? []
        let prefix = setting.rawValue + "_"
        var maxIndex = 0
        for name in existing where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            let digits = rest.prefix { $0.isNumber }
            if let n = Int(digits) { maxIndex = max(maxIndex, n) }
        }
        let newName = String(format: "%@%02d.mov", prefix, maxIndex + 1)
        let dst = clipsDirectory.appendingPathComponent(newName)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: clip, to: dst)
            return newName
        } catch {
            return clip.lastPathComponent
        }
    }

    /// Copy an imported file into the clip store, keeping its extension.
    ///
    /// Copied rather than analysed in place, for two reasons: a file picked
    /// from Files or iCloud Drive lives behind a security-scoped URL that is
    /// only valid for the length of the picker callback, and a swing record
    /// that points at somebody else's document would break the moment they
    /// moved it. The store owns every clip it references.
    /// Clip files no swing points at, deleted. Returns how many went.
    ///
    /// Called at launch, when nothing can be mid-analysis. The app already had
    /// a sweep, but it was keyed on `lastImportedClip` — an in-memory property
    /// with no persistence — and it ran inside `beginAnalysis`, which a REFUSED
    /// import never reaches. So the one file most likely to be an orphan was
    /// the one the sweep could never see, and every launch could strand one
    /// more. Each stranded file then blocked its own clip from ever being
    /// imported again.
    ///
    /// Conservative about what it will touch: only files in the clips
    /// directory, and only when the caller has supplied the full set of
    /// referenced names. An empty store with clips on disk is a first launch
    /// before the swings have loaded, not a directory full of orphans, so the
    /// caller has to say it means it.
    @discardableResult
    static func deleteUnreferencedClips(referenced: Set<String>) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: clipsDirectory.path)) ?? []
        var removed = 0
        for name in names where !referenced.contains(name) {
            // `pending_` is a clip being written right now by the recorder.
            if name.hasPrefix("pending_") { continue }
            if (try? fm.removeItem(at: clipsDirectory.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// A destination inside the store that nothing already occupies.
    ///
    /// The name used to stamp the epoch in whole SECONDS and then delete
    /// whatever stood at that path. Two imports inside one second therefore
    /// destroyed the first clip, silently, while the swing record naming it
    /// went on pointing at the second clip's footage — a wrong measurement
    /// attached to a real reading, which is the worst kind of failure this app
    /// has. A second is a long time when the answer to "Already in Swings?" is
    /// one tap away. The Photos path made it routine rather than rare, because
    /// it named every clip it ever wrote the same thing.
    static func freeImportURL(base: String, ext: String) -> URL {
        let safeExt = ext.isEmpty ? "mov" : ext
        // Only the separators need escaping; the rest of a Photos filename
        // (IMG_6824.MOV) is already a legal path component, and mangling it
        // further would lose the one thing that makes the file recognisable in
        // a duplicate question.
        var safeBase = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if safeBase.isEmpty { safeBase = "clip" }
        let stamp = Int(Date().timeIntervalSince1970)
        let fm = FileManager.default
        var url = clipsDirectory.appendingPathComponent("import_\(stamp)_\(safeBase).\(safeExt)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = clipsDirectory
                .appendingPathComponent("import_\(stamp)_\(safeBase)_\(n).\(safeExt)")
            n += 1
        }
        return url
    }

    static func importClip(from source: URL) throws -> URL {
        let dst = freeImportURL(base: source.deletingPathExtension().lastPathComponent,
                                ext: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: dst)
        return dst
    }

    /// A clip already in the store with the same byte count as `source`.
    ///
    /// Size alone, deliberately. A content hash would be exact and would mean
    /// reading every stored clip end to end — hundreds of megabytes of 240fps
    /// video — to answer a question asked before an import. Two different
    /// recordings agreeing to the byte is vanishingly unlikely, and the caller
    /// confirms with duration before saying anything, so the cost of the rare
    /// collision is one extra `AVAsset` load rather than a wrong answer.
    /// - Parameter referenced: filenames a stored swing actually points at.
    ///   Only these count.
    ///
    /// The directory is NOT the history. It also holds clips whose analysis
    /// found nothing, clips whose long-clip prompt was cancelled, and anything
    /// a crash left behind — files with no swing record, invisible in the app
    /// and deletable from nowhere in it. Matching against those refused an
    /// import by naming a clip "which is in Swings" that was not in Swings,
    /// and the refusal could never clear the file causing it, so that clip
    /// became permanently un-importable. That is the bug the owner reported as
    /// "the app refuse to accept other videos, which i dont know why".
    static func existingClipMatchingSize(of source: URL,
                                         referenced: Set<String>) -> URL? {
        let bytes = size(of: source)
        guard bytes > 0 else { return nil }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: clipsDirectory.path)) ?? []
        for name in names where referenced.contains(name) {
            let url = clipsDirectory.appendingPathComponent(name)
            if url.path != source.path, size(of: url) == bytes { return url }
        }
        return nil
    }

    static func delete(clipNamed name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: clipURL(named: name))
    }

    static func delete(trackNamed name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: trackURL(named: name))
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func totalClipBytes() -> Int64 {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: clipsDirectory.path)) ?? []
        return names.reduce(0) { $0 + size(of: clipsDirectory.appendingPathComponent($1)) }
    }
}
