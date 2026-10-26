import SwiftUI
import Photos
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// The native counterpart of the web photo-information editor.
/// It deliberately lives beside PhotoBridge's transfer flows so editing a
/// photo never changes the album-order backup or restore state.
struct PhotoInfoView: View {
    @StateObject private var model = PhotoInfoModel()
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                            Label("选择原始照片", systemImage: "photo.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(BridgeButtonStyle(primary: true))
                        .tint(.bridgeBlue)
                        .controlSize(.large)
                        .disabled(model.busy)
                        if !model.items.isEmpty { photoStrip }
                        if let selected = model.selected {
                            editor(selected)
                        } else {
                            BridgeCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("编辑拍摄信息", systemImage: "slider.horizontal.3")
                                        .font(.headline)
                                    Text("选择照片，调整拍摄信息、时间或尺寸，再保存为新副本。支持 JPEG、HEIC 和 PNG。")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if model.busy { progressCard }
                        if let message = model.message {
                            Text(message).font(.footnote).foregroundStyle(model.failed ? .red : .secondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationBarHidden(true)
        }
        .task(id: pickerItems) { await model.importItems(pickerItems) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("照片信息").font(.largeTitle.bold()).foregroundStyle(Color.bridgeInk)
                Text("编辑后直接存入 iPhone，不覆盖原照片").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.items.isEmpty {
                Text("\(model.items.count) 张").font(.subheadline.weight(.medium)).foregroundStyle(Color.bridgeMuted)
            }
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    Button { model.selectedIndex = index } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: item.preview).resizable().scaledToFill()
                            Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(4).background(.black.opacity(0.55), in: Capsule()).padding(4)
                        }
                        .frame(width: 68, height: 68).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(index == model.selectedIndex ? Color.bridgeBlue : .clear, lineWidth: 3))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func editor(_ item: PhotoInfoItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BridgeCard {
                VStack(alignment: .leading, spacing: 14) {
                    Image(uiImage: item.preview).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    HStack {
                        Text(item.filename).font(.headline).lineLimit(1)
                        Spacer()
                        Text(item.format.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.bridgeMuted)
                    }
                    Divider()
                    Group {
                        field("相机品牌", keyPath: \ .make, placeholder: "Apple")
                        field("相机型号", keyPath: \ .model, placeholder: "iPhone")
                        field("镜头", keyPath: \ .lens, placeholder: "无镜头信息")
                        field("软件", keyPath: \ .software, placeholder: "")
                    }
                    HStack(spacing: 10) {
                        numberField("ISO", value: binding(\.iso), keyboard: .numberPad)
                        numberField("ƒ", value: binding(\.aperture), keyboard: .decimalPad)
                        numberField("快门", value: binding(\.shutter), keyboard: .numbersAndPunctuation)
                    }
                    HStack(spacing: 10) {
                        numberField("焦距 mm", value: binding(\.focal), keyboard: .decimalPad)
                        numberField("等效 mm", value: binding(\.equivalent), keyboard: .numberPad)
                        numberField("EV", value: binding(\.ev), keyboard: .numbersAndPunctuation)
                    }
                    HStack(spacing: 10) {
                        numberField("日期", value: binding(\.date), keyboard: .numbersAndPunctuation)
                        Text("EV=0 也会写入元数据").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            resolutionEditor(item)
            Button { Task { await model.saveSelectedToLibrary() } } label: {
                Label("存入 iPhone 相册", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BridgeButtonStyle(primary: true)).tint(.bridgeBlue).controlSize(.large).disabled(model.busy)
        }
    }

    private func resolutionEditor(_ item: PhotoInfoItem) -> some View {
        BridgeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("分辨率", systemImage: "rectangle.resize")
                    Spacer()
                    Text("\(item.width) × \(item.height)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.bridgeMuted)
                }
                Toggle("锁定 3:4 比例", isOn: Binding(get: { model.selected?.draft.lock34 ?? false }, set: { model.setLock34($0) }))
                    .font(.subheadline)
                HStack(spacing: 10) {
                    TextField("宽", value: Binding(get: { model.selected?.draft.width ?? 0 }, set: { model.setWidth($0) }), format: .number).keyboardType(.numberPad)
                    Text("×").foregroundStyle(.secondary)
                    TextField("高", value: Binding(get: { model.selected?.draft.height ?? 0 }, set: { model.setHeight($0) }), format: .number).keyboardType(.numberPad)
                }
                .textFieldStyle(.roundedBorder)
                Text("开启后修改一边会同步另一边，保存时居中裁切并重新编码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var progressCard: some View {
        BridgeCard {
            VStack(alignment: .leading, spacing: 9) {
                ProgressView(value: model.progress)
                Text(model.progressText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ title: String, keyPath: WritableKeyPath<PhotoInfoDraft, String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            TextField(placeholder, text: binding(keyPath)).textFieldStyle(.roundedBorder)
        }
    }

    private func numberField(_ title: String, value: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("—", text: value).keyboardType(keyboard).textFieldStyle(.roundedBorder)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PhotoInfoDraft, T>) -> Binding<T> {
        Binding(get: { model.selected?.draft[keyPath: keyPath] ?? PhotoInfoDraft()[keyPath: keyPath] }, set: { model.updateSelected(keyPath, value: $0) })
    }
}

@MainActor
final class PhotoInfoModel: ObservableObject {
    @Published var items: [PhotoInfoItem] = []
    @Published var selectedIndex = 0
    @Published var busy = false { didSet { PhoneActivity.shared.set("photo-info", active: busy) } }
    @Published var progress = 0.0
    @Published var progressText = ""
    @Published var message: String?
    @Published var failed = false

    var selected: PhotoInfoItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func importItems(_ pickerItems: [PhotosPickerItem]) async {
        guard !pickerItems.isEmpty else { return }
        busy = true; failed = false; message = nil; progress = 0; progressText = "正在读取照片…"
        var loaded: [PhotoInfoItem] = []
        for (index, picker) in pickerItems.enumerated() {
            do {
                guard let data = try await picker.loadTransferable(type: Data.self) else { throw PhotoInfoError.invalidImage }
                let filename = await PhotoInfoLibrary.filename(for: picker.itemIdentifier) ?? "照片-\(index + 1).jpg"
                loaded.append(try PhotoInfoItem(data: data, filename: filename))
                progress = Double(index + 1) / Double(pickerItems.count)
                progressText = "已读取 \(index + 1)/\(pickerItems.count) 张"
            } catch { message = "读取失败：\(error.localizedDescription)"; failed = true }
        }
        if !loaded.isEmpty { items = loaded; selectedIndex = 0; message = "已读取 \(loaded.count) 张照片" }
        busy = false
    }

    func updateSelected<T>(_ keyPath: WritableKeyPath<PhotoInfoDraft, T>, value: T) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].draft[keyPath: keyPath] = value
    }

    func setLock34(_ value: Bool) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].draft.lock34 = value
        if value { setWidth(items[selectedIndex].draft.width) }
    }

    func setWidth(_ value: Int) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].draft.width = max(1, value)
        if items[selectedIndex].draft.lock34 { items[selectedIndex].draft.height = max(1, Int(Double(value) * 4.0 / 3.0)) }
    }

    func setHeight(_ value: Int) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].draft.height = max(1, value)
        if items[selectedIndex].draft.lock34 { items[selectedIndex].draft.width = max(1, Int(Double(value) * 3.0 / 4.0)) }
    }

    func saveSelectedToLibrary() async {
        guard let item = selected else { return }
        busy = true; failed = false; message = nil; progress = 0; progressText = "正在生成照片…"
        do {
            let data = try item.exportData()
            try await PhotoInfoLibrary.save(data: data, uti: item.uti)
            progress = 1; progressText = "已保存到 iPhone 相册"
            message = "保存完成：系统照片中已新增一张照片"; busy = false
        } catch { message = "保存未完成：\(error.localizedDescription)"; failed = true; busy = false }
    }
}

struct PhotoInfoItem: Identifiable {
    let id = UUID()
    let originalData: Data
    let filename: String
    let preview: UIImage
    let format: String
    let uti: String
    let originalWidth: Int
    let originalHeight: Int
    var draft: PhotoInfoDraft

    init(data: Data, filename: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = UIImage(data: data) else { throw PhotoInfoError.invalidImage }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        draft = PhotoInfoDraft(properties: props)
        originalData = data; self.filename = filename; preview = image
        uti = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        format = URL(fileURLWithPath: filename).pathExtension.isEmpty ? "JPEG" : URL(fileURLWithPath: filename).pathExtension
        draft.width = Int(props[kCGImagePropertyPixelWidth as String] as? NSNumber ?? 0)
        draft.height = Int(props[kCGImagePropertyPixelHeight as String] as? NSNumber ?? 0)
        originalWidth = draft.width
        originalHeight = draft.height
    }

    var width: Int { draft.width }
    var height: Int { draft.height }
    mutating func syncRatio() {
        guard draft.lock34, draft.width > 0, draft.height > 0 else { return }
        draft.height = max(1, Int(Double(draft.width) * 4.0 / 3.0))
    }

    func exportData() throws -> Data {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil) else { throw PhotoInfoError.invalidImage }
        let changed = draft.metadataChanges
        let needsResize = draft.width != originalWidth || draft.height != originalHeight
        guard needsResize || !changed.exif.isEmpty || !changed.tiff.isEmpty else { return originalData }
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, uti as CFString, 1, nil) else { throw PhotoInfoError.exportFailed }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        var exif = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        var tiff = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        for (key, value) in changed.exif { exif[key] = value }
        for (key, value) in changed.tiff { tiff[key] = value }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary as String] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        if needsResize {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let resized = Self.resize(image, width: draft.width, height: draft.height) else { throw PhotoInfoError.exportFailed }
            CGImageDestinationAddImage(destination, resized, properties as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw PhotoInfoError.exportFailed }
        return mutable as Data
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0, space: colorSpace, bitmapInfo: image.bitmapInfo.rawValue) else { return nil }
        context.interpolationQuality = .high
        let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
        let targetAspect = CGFloat(width) / CGFloat(height)
        let crop: CGRect
        if sourceAspect > targetAspect {
            let cropWidth = CGFloat(image.height) * targetAspect
            crop = CGRect(x: (CGFloat(image.width) - cropWidth) / 2, y: 0, width: cropWidth, height: CGFloat(image.height))
        } else {
            let cropHeight = CGFloat(image.width) / targetAspect
            crop = CGRect(x: 0, y: (CGFloat(image.height) - cropHeight) / 2, width: CGFloat(image.width), height: cropHeight)
        }
        guard let cropped = image.cropping(to: crop.integral) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

struct PhotoInfoDraft {
    var make = "", model = "", lens = "", software = "", iso = "", focal = "", equivalent = "", ev = "", aperture = "", shutter = "", date = ""
    var width = 0, height = 0, lock34 = false

    init() {}
    init(properties: [String: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        make = Self.string(tiff[kCGImagePropertyTIFFMake as String]); model = Self.string(tiff[kCGImagePropertyTIFFModel as String]); software = Self.string(tiff[kCGImagePropertyTIFFSoftware as String])
        lens = Self.string(exif[kCGImagePropertyExifLensModel as String]); iso = Self.string((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first)
        focal = Self.string(exif[kCGImagePropertyExifFocalLength as String]); equivalent = Self.string(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]); ev = Self.string(exif[kCGImagePropertyExifExposureBiasValue as String]); aperture = Self.string(exif[kCGImagePropertyExifFNumber as String]); shutter = Self.string(exif[kCGImagePropertyExifExposureTime as String]); date = Self.string(exif[kCGImagePropertyExifDateTimeOriginal as String])
    }
    var metadataChanges: (exif: [String: Any], tiff: [String: Any]) {
        var e: [String: Any] = [:], t: [String: Any] = [:]
        if !make.isEmpty { t[kCGImagePropertyTIFFMake as String] = make }; if !model.isEmpty { t[kCGImagePropertyTIFFModel as String] = model }; if !software.isEmpty { t[kCGImagePropertyTIFFSoftware as String] = software }
        if !lens.isEmpty { e[kCGImagePropertyExifLensModel as String] = lens }; if !iso.isEmpty { e[kCGImagePropertyExifISOSpeedRatings as String] = [Int(iso) ?? 0] }; if !focal.isEmpty { e[kCGImagePropertyExifFocalLength as String] = Double(focal) ?? 0 }; if !equivalent.isEmpty { e[kCGImagePropertyExifFocalLenIn35mmFilm as String] = Int(equivalent) ?? 0 }; if !ev.isEmpty { e[kCGImagePropertyExifExposureBiasValue as String] = Double(ev) ?? 0 }; if !aperture.isEmpty { e[kCGImagePropertyExifFNumber as String] = Double(aperture) ?? 0 }; if !shutter.isEmpty { e[kCGImagePropertyExifExposureTime as String] = Self.exposure(shutter) }; if !date.isEmpty { e[kCGImagePropertyExifDateTimeOriginal as String] = date }
        return (e, t)
    }
    static func string(_ value: Any?) -> String { if let n = value as? NSNumber { return n.stringValue }; return value as? String ?? "" }
    static func exposure(_ value: String) -> Double { if value.contains("/") { let p = value.split(separator: "/"); if p.count == 2 { return (Double(p[0]) ?? 0) / (Double(p[1]) ?? 1) } }; return Double(value) ?? 0 }
}

enum PhotoInfoLibrary {
    static func filename(for id: String?) async -> String? {
        guard let id, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }
    static func save(data: Data, uti: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .addOnly)) else { throw PhotoInfoError.permissionDenied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions(); options.uniformTypeIdentifier = uti
                request.addResource(with: .photo, data: data, options: options)
            }) { success, error in
                if success { continuation.resume() } else { continuation.resume(throwing: error ?? PhotoInfoError.exportFailed) }
            }
        }
    }
}

enum PhotoInfoError: LocalizedError {
    case invalidImage, exportFailed, permissionDenied
    var errorDescription: String? {
        switch self { case .invalidImage: return "无法读取这张照片"; case .exportFailed: return "照片生成失败"; case .permissionDenied: return "请允许 PhotoBridge 添加照片到相册" }
    }
}
