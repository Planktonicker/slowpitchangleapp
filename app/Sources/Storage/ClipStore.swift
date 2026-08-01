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
