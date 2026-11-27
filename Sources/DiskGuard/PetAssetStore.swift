import Foundation
import AppKit
import CoreImage
import Vision
import DiskGuardCore

public enum PetImportError: LocalizedError, Sendable {
    case missingPrimaryImage
    case unreadableImage(String)
    case encodingFailed
    case cannotDeleteBuiltIn
    case invalidTargetDirectory

    public var errorDescription: String? {
        switch self {
        case .missingPrimaryImage:
            return "请至少选择一张「默认 / 悠闲」主图。"
        case .unreadableImage(let name):
            return "无法读取图片「\(name)」，请选择 PNG、JPEG、HEIC 或 WebP 文件。"
        case .encodingFailed:
            return "生成透明 PNG 时发生错误，请换一张图片重试。"
        case .cannotDeleteBuiltIn:
            return "默认内置的西高地形象不可删除。"
        case .invalidTargetDirectory:
            return "自定义宠物目录路径无效，已阻止删除操作。"
        }
    }
}

@MainActor
public final class PetAssetStore: ObservableObject {
    @Published public private(set) var availablePacks: [PetPack] = []

    private var imageCache: [String: NSImage] = [:]
    private var cgImageCache: [String: CGImage] = [:]
    private let customRootOverride: URL?

    public init(customRootOverride: URL? = nil) {
        self.customRootOverride = customRootOverride
        reloadPacks()
    }

    public var customPetsDirectoryURL: URL {
        if let customRootOverride {
            return customRootOverride
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("DiskGuard", isDirectory: true)
            .appendingPathComponent("Pets", isDirectory: true)
    }

    public func reloadPacks() {
        var packs: [PetPack] = []
        if let builtIn = loadBuiltInWestiePack() {
            packs.append(builtIn)
        }

        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(
            at: customPetsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var customPacks: [PetPack] = []
            for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let pack = loadPack(from: dir, isBuiltIn: false) else {
                    continue
                }
                customPacks.append(pack)
            }
            packs.append(contentsOf: customPacks)
        }

        availablePacks = packs
    }

    public func pack(for id: String) -> PetPack? {
        if let match = availablePacks.first(where: { $0.id == id }) {
            return match
        }
        return availablePacks.first(where: { $0.id == PetPack.builtInWestieID }) ?? availablePacks.first
    }

    public func image(for pack: PetPack, mood: PetMood) -> NSImage? {
        let key = "\(pack.id)::\(mood.rawValue)"
        if let cached = imageCache[key] {
            return cached
        }
        guard let url = pack.imageURL(for: mood),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        imageCache[key] = img
        return img
    }

    public func cgImage(for pack: PetPack, mood: PetMood) -> CGImage? {
        let key = "\(pack.id)::\(mood.rawValue)"
        if let cached = cgImageCache[key] {
            return cached
        }
        guard let nsImage = image(for: pack, mood: mood) else { return nil }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        if let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            cgImageCache[key] = cg
            return cg
        }
        return nil
    }

    public func importCustomPet(
        name: String,
        moodSourceURLs: [PetMood: URL],
        removeBackground: Bool
    ) async throws -> PetPack {
        guard moodSourceURLs[.idle] != nil else {
            throw PetImportError.missingPrimaryImage
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "我的桌宠" : String(trimmedName.prefix(20))
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let rootURL = customPetsDirectoryURL
        let destDir = rootURL.appendingPathComponent(id, isDirectory: true)

        let pack = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            var moodFilesMap: [String: String] = [:]
            var resolvedMoods: [PetMood: String] = [:]

            for mood in PetMood.allCases {
                guard let srcURL = moodSourceURLs[mood] else { continue }
                guard let cgImage = Self.processImage(at: srcURL, removeBackground: removeBackground, maxDimension: 512) else {
                    throw PetImportError.unreadableImage(srcURL.lastPathComponent)
                }
                let filename = "\(mood.rawValue).png"
                let outURL = destDir.appendingPathComponent(filename)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let pngData = rep.representation(using: .png, properties: [:]) else {
                    throw PetImportError.encodingFailed
                }
                try pngData.write(to: outURL, options: .atomic)
                moodFilesMap[mood.rawValue] = filename
                resolvedMoods[mood] = filename
            }

            let manifest = PetPackManifest(id: id, name: displayName, version: 1, moodFiles: moodFilesMap)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: destDir.appendingPathComponent("manifest.json"), options: .atomic)

            return PetPack(
                id: id,
                name: displayName,
                isBuiltIn: false,
                directoryURL: destDir,
                moodFiles: resolvedMoods
            )
        }.value

        imageCache = imageCache.filter { !$0.key.hasPrefix("\(id)::") }
        cgImageCache = cgImageCache.filter { !$0.key.hasPrefix("\(id)::") }
        reloadPacks()
        return pack
    }

    public func deleteCustomPet(id: String) throws {
        guard id != PetPack.builtInWestieID else {
            throw PetImportError.cannotDeleteBuiltIn
        }
        guard let target = availablePacks.first(where: { $0.id == id && !$0.isBuiltIn }) else {
            return
        }

        let rootPath = customPetsDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = target.directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix), targetPath != rootPath else {
            throw PetImportError.invalidTargetDirectory
        }

        try FileManager.default.removeItem(at: target.directoryURL)
        imageCache = imageCache.filter { !$0.key.hasPrefix("\(id)::") }
        cgImageCache = cgImageCache.filter { !$0.key.hasPrefix("\(id)::") }
        reloadPacks()
    }

    // MARK: - Built-in Discovery & Manifest Parsing

    private func loadBuiltInWestiePack() -> PetPack? {
        for dir in mainBundleWestieCandidates() {
            if let pack = loadPackOrFallback(from: dir) {
                return pack
            }
        }
        if let moduleRes = Bundle.module.resourceURL {
            let dir = moduleRes.appendingPathComponent("Pets/westie", isDirectory: true)
            if let pack = loadPackOrFallback(from: dir) {
                return pack
            }
        }
        return nil
    }

    private func loadPackOrFallback(from dir: URL) -> PetPack? {
        if let pack = loadPack(from: dir, isBuiltIn: true) {
            return pack
        }
        let fallbackIdle = dir.appendingPathComponent("idle.png")
        guard FileManager.default.fileExists(atPath: fallbackIdle.path) else {
            return nil
        }
        var moodFiles: [PetMood: String] = [:]
        for mood in PetMood.allCases {
            let file = "\(mood.rawValue).png"
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                moodFiles[mood] = file
            }
        }
        return PetPack(
            id: PetPack.builtInWestieID,
            name: "西高地",
            isBuiltIn: true,
            directoryURL: dir,
            moodFiles: moodFiles
        )
    }

    private func mainBundleWestieCandidates() -> [URL] {
        var urls: [URL] = []
        if let mainRes = Bundle.main.resourceURL {
            urls.append(mainRes.appendingPathComponent("Pets/westie", isDirectory: true))
            urls.append(
                mainRes
                    .appendingPathComponent("DiskGuard_DiskGuard.bundle", isDirectory: true)
                    .appendingPathComponent("Pets/westie", isDirectory: true)
            )
        }
        let bundleDir = Bundle.main.bundleURL
        urls.append(
            bundleDir
                .appendingPathComponent("DiskGuard_DiskGuard.bundle", isDirectory: true)
                .appendingPathComponent("Pets/westie", isDirectory: true)
        )
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(
                executableDir
                    .appendingPathComponent("DiskGuard_DiskGuard.bundle", isDirectory: true)
                    .appendingPathComponent("Pets/westie", isDirectory: true)
            )
        }
        return urls
    }

    private func loadPack(from directoryURL: URL, isBuiltIn: Bool) -> PetPack? {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetPackManifest.self, from: data) else {
            return nil
        }
        var moods: [PetMood: String] = [:]
        for (rawMood, filename) in manifest.moodFiles {
            if let mood = PetMood(rawValue: rawMood) {
                moods[mood] = filename
            }
        }
        guard moods[.idle] != nil else { return nil }
        return PetPack(
            id: manifest.id,
            name: manifest.name,
            isBuiltIn: isBuiltIn,
            directoryURL: directoryURL,
            moodFiles: moods
        )
    }

    // MARK: - On-Device Vision Cutout & Normalization

    nonisolated public static func processImage(
        at sourceURL: URL,
        removeBackground: Bool,
        maxDimension: Int = 512
    ) -> CGImage? {
        guard let inputCI = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
            return nil
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var workingCI = inputCI

        if removeBackground {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: inputCI, options: [:])
            if (try? handler.perform([request])) != nil,
               let observation = request.results?.first,
               !observation.allInstances.isEmpty,
               let maskBuffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                let maskCI = CIImage(cvPixelBuffer: maskBuffer)
                if let blend = CIFilter(name: "CIBlendWithMask") {
                    blend.setValue(inputCI, forKey: kCIInputImageKey)
                    blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
                    blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
                    if let masked = blend.outputImage {
                        workingCI = masked
                    }
                }
            }
        }

        guard let rawCG = ciContext.createCGImage(workingCI, from: inputCI.extent) else {
            return nil
        }
        return normalizeCanvas(rawCG, maxDimension: maxDimension)
    }

    nonisolated private static func normalizeCanvas(_ sourceCG: CGImage, maxDimension: Int) -> CGImage? {
        let width = sourceCG.width
        let height = sourceCG.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * 4 + 3]
                if alpha >= 14 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        let cropped: CGImage
        if maxX >= minX, maxY >= minY {
            let pad = 4
            let cx = max(0, minX - pad)
            let cy = max(0, minY - pad)
            let cw = min(width - cx, (maxX - minX + 1) + pad * 2)
            let ch = min(height - cy, (maxY - minY + 1) + pad * 2)
            cropped = sourceCG.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) ?? sourceCG
        } else {
            cropped = sourceCG
        }

        let targetSize = max(64, maxDimension)
        let usable = CGFloat(targetSize) * 0.88
        let scale = min(usable / CGFloat(cropped.width), usable / CGFloat(cropped.height))
        let drawW = CGFloat(cropped.width) * scale
        let drawH = CGFloat(cropped.height) * scale
        let drawX = (CGFloat(targetSize) - drawW) * 0.5
        let drawY = CGFloat(targetSize) * 0.06

        guard let outCtx = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        outCtx.interpolationQuality = .high
        outCtx.clear(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        outCtx.draw(cropped, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        return outCtx.makeImage()
    }
}
