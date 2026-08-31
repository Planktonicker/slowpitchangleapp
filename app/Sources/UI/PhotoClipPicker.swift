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

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Result<URL, Error>) -> Void
        init(onPick: @escaping (Result<URL, Error>) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
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

            let ext = (resource.originalFilename as NSString).pathExtension
            let dst = ClipStore.clipsDirectory.appendingPathComponent(
                "import_\(Int(Date().timeIntervalSince1970))_original.\(ext.isEmpty ? "mov" : ext)")
            try? FileManager.default.removeItem(at: dst)

            let options = PHAssetResourceRequestOptions()
            // The clip may live only in iCloud. Without this the write fails on
            // exactly the clips a phone short of space is most likely to hold.
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(for: resource, toFile: dst,
                                                       options: options) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        // Fall back rather than fail: a 30fps render analyses,
                        // and being told the rate is wrong beats being told
                        // nothing at all.
                        _ = error
                        self?.copyRendered(from: provider)
                    } else {
                        self?.onPick(.success(dst))
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
            provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                // The provider's file is deleted the moment this closure
                // returns — which is why the copy happens HERE, synchronously,
                // on the provider's queue. The old code hopped to the main
                // queue first, returned, and then tried to copy a file the
                // system had already deleted: every clip taking this fallback
                // failed with "could not read that file" despite being fine.
                // Only the RESULT goes to the main queue.
                guard let url else {
                    DispatchQueue.main.async {
                        self?.onPick(.failure(error ?? PickError.notAMovie))
                    }
                    return
                }
                let result = Result { try ClipStore.importClip(from: url) }
                DispatchQueue.main.async { self?.onPick(result) }
            }
        }
    }

    enum PickError: LocalizedError {
        case notAMovie
        var errorDescription: String? { "That item is not a video this app can read." }
    }
}
