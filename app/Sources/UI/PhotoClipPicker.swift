// SwingLab — Copyright (C) 2026 Planktonicker
// SPDX-License-Identifier: AGPL-3.0-only
// Full terms in LICENSE at the repository root. No warranty.

import Photos
import PhotosUI
import UniformTypeIdentifiers
import SwiftUI
import UIKit

/// Picks a clip from Photos and hands back the **original** file.
///
/// This exists because the document picker cannot do it. An iPhone slow-motion
/// video is stored as two things: the original recording, which really is
/// 240fps, and a slow-motion *edit* applied on top of it. Every ordinary export
/// path — the Files picker, Share, AirDrop from Photos, `loadFileRepresentation`
/// — renders the edit and hands over the result, which is 30fps with the slow
/// motion baked in. The frames are still there; they have just been spread out
/// over eight times the duration and the file now says 30.
///
/// That is fatal here rather than merely lossy. Exit velocity is pixels per
/// frame times frame rate, so a clip that claims 30 when it was shot at 240 is
/// wrong by a factor of eight, and nothing downstream can tell.
///
/// The original is reachable through `PHAssetResource`, which is why this uses
/// `PHPickerViewController` with a photo library attached rather than the
/// SwiftUI `PhotosPicker`: the results then carry an asset identifier, and the
/// identifier is what makes the original addressable.
struct PhotoClipPicker: UIViewControllerRepresentable {

    /// Called with the copied file, or an explanation.
    var onPick: (Result<URL, Error>) -> Void

    /// Called the moment the picker is finished with, so the presenter can
    /// clear its own binding.
    ///
    /// This is not a nicety. The picker used to dismiss itself with
    /// `picker.dismiss(animated:)` — the only imperative dismissal in the app
    /// — and SwiftUI is not told when that happens, so the `sheet` binding
    /// that presented it stayed set. `.sheet(item:)` keys on `id`, and this
    /// case's id is a constant, so assigning `.photoPicker` a second time was
    /// not a change and NOTHING HAPPENED. The button went dead, silently, for
    /// the rest of the screen's life — with no banner, because no code ran.
    /// That is the whole of "the app refuse to accept other videos, which i
    /// dont know why": after the first successful pick, there was no second.
    var onFinish: () -> Void

    /// Fraction of an iCloud fetch, on the main queue. Nil once it is done.
    ///
    /// A clip that lives only in iCloud has to come down before it can be
    /// copied, and that can take minutes on a phone. Without this the sheet
    /// closes onto an idle screen with nothing spinning, which is
    /// indistinguishable from a tap that did nothing — so the natural response
    /// is to tap again, which is the worst thing to do.
    var onDownload: (Double?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // `photoLibrary:` matters: without it the results carry no
        // assetIdentifier and the original is unreachable.
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        // Ask for the asset as it is stored rather than a transcode. Belt and
        // braces next to the resource path below, and it is what makes the
        // fallback path merely bad rather than useless.
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish, onDownload: onDownload)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Result<URL, Error>) -> Void
        let onFinish: () -> Void
        let onDownload: (Double?) -> Void
        init(onPick: @escaping (Result<URL, Error>) -> Void,
             onFinish: @escaping () -> Void,
             onDownload: @escaping (Double?) -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
            self.onDownload = onDownload
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Dismissed through the presenter's binding rather than by the
            // controller itself — see `onFinish`. Cancel takes this path too:
            // PHPicker reports a cancel as an empty result set and does not
            // close itself.
            onFinish()
            guard let result = results.first else { return }

            if let id = result.assetIdentifier,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                copyOriginal(of: asset, fallback: result.itemProvider)
            } else {
                // No library permission, or a result from somewhere that has no
                // asset behind it. The rendered export is all that is available;
                // it is still worth analysing, and the frame rate it reports is
                // what the diagnostics will flag.
                copyRendered(from: result.itemProvider)
            }
        }

        /// Write the untouched recording out of the photo library.
        private func copyOriginal(of asset: PHAsset, fallback provider: NSItemProvider) {
            let resources = PHAssetResource.assetResources(for: asset)
            // `.video` is the original recording. `.fullSizeVideo` is the
            // rendered result of whatever edits are applied — for slow motion
            // that is the 30fps version, which is the thing being avoided.
            guard let resource = resources.first(where: { $0.type == .video })
                    ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
                copyRendered(from: provider)
                return
            }

            // The asset's OWN filename, not the literal word "original".
            //
            // Every Photos import used to be written to
            // `import_<epoch>_original.MOV`, with the existing file at that
            // path deleted first — so two imports inside one second destroyed
            // the first clip while the swing naming it went on pointing at the
            // path, which now held different footage. The real filename was
            // sitting on the line above, discarded. It is also the only thing
            // that makes a duplicate question answerable: "IMG_6824.MOV" is
            // recognisable in Photos; "original" is not.
            let name = (resource.originalFilename as NSString)
            let dst = ClipStore.freeImportURL(base: name.deletingPathExtension,
                                              ext: name.pathExtension)

            let options = PHAssetResourceRequestOptions()
            // The clip may live only in iCloud. Without this the write fails on
            // exactly the clips a phone short of space is most likely to hold.
            options.isNetworkAccessAllowed = true
            // Called on a background queue, repeatedly, for the length of the
            // download.
            let report = onDownload
            options.progressHandler = { fraction in
                DispatchQueue.main.async { report(fraction) }
            }

            // STRONG self, deliberately.
            //
            // `onFinish()` has already run by now, so SwiftUI has torn the
            // representable down and this Coordinator has no other owner. With
            // `[weak self]` the file finished downloading, landed on disk, and
            // then the result was dropped on the floor: no row, no banner, no
            // report — and a clip file in the store that no swing pointed at,
            // which by `ClipStore.existingClipMatchingSize` then refused the
            // next import of that same video. Holding self here keeps the
            // Coordinator alive exactly until the callback fires; the closure
            // is owned by PHAssetResourceManager, not by the Coordinator, so
            // there is no cycle to leak.
            PHAssetResourceManager.default().writeData(for: resource, toFile: dst,
                                                       options: options) { error in
                DispatchQueue.main.async {
                    self.onDownload(nil)
                    if let error {
                        // Fall back rather than fail: a 30fps render analyses,
                        // and being told the rate is wrong beats being told
                        // nothing at all.
                        _ = error
                        // The part-written file goes, or it is an orphan that
                        // blocks this clip's own re-import for ever.
                        try? FileManager.default.removeItem(at: dst)
                        self.copyRendered(from: provider)
                    } else {
                        self.onPick(.success(dst))
                    }
                }
            }
        }

        /// The ordinary path, kept as a fallback.
        private func copyRendered(from provider: NSItemProvider) {
            let type = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else {
                onPick(.failure(PickError.notAMovie))
                return
            }
            // STRONG self, for the reason given in `copyOriginal`.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // The provider's file is deleted the moment this closure
                // returns — which is why the copy happens HERE, synchronously,
                // on the provider's queue. The old code hopped to the main
                // queue first, returned, and then tried to copy a file the
                // system had already deleted: every clip taking this fallback
                // failed with "could not read that file" despite being fine.
                // Only the RESULT goes to the main queue.
                guard let url else {
                    DispatchQueue.main.async {
                        self.onPick(.failure(error ?? PickError.notAMovie))
                    }
                    return
                }
                let result = Result { try ClipStore.importClip(from: url) }
                DispatchQueue.main.async { self.onPick(result) }
            }
        }
    }

    enum PickError: LocalizedError {
        case notAMovie
        var errorDescription: String? { "That item is not a video this app can read." }
    }
}
