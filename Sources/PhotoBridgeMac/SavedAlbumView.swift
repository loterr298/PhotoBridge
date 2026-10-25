import AppKit
import SwiftUI
import QuickLookThumbnailing

@MainActor
private enum AlbumThumbnailCache {
    static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
}

private struct SavedPhotoThumbnail: View {
    let photo: BackupAssetPreview
    @State private var image: NSImage?
    @State private var request: QLThumbnailGenerator.Request?
    @State private var loading = true
    var body: some View {
        Button { NSWorkspace.shared.open(photo.mediaURL) } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
                }
                .frame(height: 156).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                Text(String(format: "%06d", photo.ordinal)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(photo.primaryFilename).font(.caption).foregroundStyle(.primary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(photo.ordinal) 张，\(photo.primaryFilename)")
        .onAppear { load() }
        .onDisappear {
            if let request { QLThumbnailGenerator.shared.cancel(request) }
            request = nil; image = nil
        }
    }
    private func load() {
        if let cached = AlbumThumbnailCache.images.object(forKey: photo.mediaURL as NSURL) {
            image = cached; loading = false; return
        }
        loading = true
        let ticket = QLThumbnailGenerator.Request(fileAt: photo.mediaURL, size: CGSize(width: 192, height: 192),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        request = ticket
        QLThumbnailGenerator.shared.generateBestRepresentation(for: ticket) { representation, _ in
            DispatchQueue.main.async {
                guard request === ticket else { return }
                if let result = representation?.nsImage {
                    image = result
                    let pixels = representation.map { $0.cgImage.width * $0.cgImage.height * 4 } ?? 0
                    AlbumThumbnailCache.images.setObject(result, forKey: photo.mediaURL as NSURL, cost: pixels)
                }
                loading = false
            }
        }
    }
}

struct SavedAlbumView: View {
    @ObservedObject var model: MacTransferModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.savedAlbumName).font(.title2.bold())
                    Text(model.loadingPreview ? "正在读取已保存的照片…" : "已保存 \(model.backupPreview.count.formatted()) 张，按相册顺序排列")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择其他相册") { model.chooseSavedAlbum() }
                Button("打开文件夹") { model.openSavedFolder() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.loadingPreview {
                Spacer()
                ProgressView("正在读取照片…").frame(maxWidth: .infinity)
                Spacer()
            } else if model.backupPreview.isEmpty {
                Spacer()
                Text(model.previewError.isEmpty ? "照片保存到 Mac 后，会显示在这里。" : model.previewError).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 14)], spacing: 20) {
                        ForEach(model.backupPreview) { photo in SavedPhotoThumbnail(photo: photo) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(24).frame(minWidth: 740, minHeight: 560)
    }
}
