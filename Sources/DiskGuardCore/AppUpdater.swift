import Foundation
import CryptoKit

public struct SemVer: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    public init?(_ raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        let corePart: Substring
        if let dashIdx = trimmed.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            corePart = trimmed[..<dashIdx]
        } else {
            corePart = Substring(trimmed)
        }

        let parts = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let maj = Int(parts[0]), maj >= 0,
              let min = Int(parts[1]), min >= 0 else {
            return nil
        }
        let pat: Int
        if parts.count == 3 {
            guard let parsedPatch = Int(parts[2]), parsedPatch >= 0 else {
                return nil
            }
            pat = parsedPatch
        } else {
            pat = 0
        }
        self.init(major: maj, minor: min, patch: pat)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public var displayTag: String {
        "v\(description)"
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct ReleaseInfo: Sendable, Equatable, Identifiable {
    public var id: String { tagName }
    public let tagName: String
    public let version: SemVer
    public let title: String
    public let notes: String
    public let htmlURL: URL?
    public let assetName: String
    public let assetID: Int?
    public let browserDownloadURL: URL
    public let sha256AssetName: String?
    public let sha256AssetID: Int?
    public let sha256DownloadURL: URL?
    public let publishedAt: String?

    public init(
        tagName: String,
        version: SemVer,
        title: String,
        notes: String,
        htmlURL: URL?,
        assetName: String,
        assetID: Int?,
        browserDownloadURL: URL,
        sha256AssetName: String?,
        sha256AssetID: Int?,
        sha256DownloadURL: URL?,
        publishedAt: String?
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.notes = notes
        self.htmlURL = htmlURL
        self.assetName = assetName
        self.assetID = assetID
        self.browserDownloadURL = browserDownloadURL
        self.sha256AssetName = sha256AssetName
        self.sha256AssetID = sha256AssetID
        self.sha256DownloadURL = sha256DownloadURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckOutcome: Sendable, Equatable {
    case upToDate(current: SemVer, latest: SemVer)
    case updateAvailable(current: SemVer, release: ReleaseInfo)
    case noReleasesYet(current: SemVer)
}

public struct PreparedUpdate: Sendable {
    public let release: ReleaseInfo
    public let stagedAppURL: URL
    public let tempDirectory: URL
    public let verifiedSHA256: String

    public init(release: ReleaseInfo, stagedAppURL: URL, tempDirectory: URL, verifiedSHA256: String) {
        self.release = release
        self.stagedAppURL = stagedAppURL
        self.tempDirectory = tempDirectory
        self.verifiedSHA256 = verifiedSHA256
    }
}

public enum UpdateError: Error, LocalizedError, Sendable, Equatable {
    case notRunningFromAppBundle
    case authenticationRequired
    case httpError(Int)
    case invalidReleasePayload(String)
    case noInstallableAsset
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case bundleValidationFailed(String)
    case signatureVerificationFailed(String)
    case launchHelperFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            return "当前未从 .app 应用包运行或应用所在目录不可写，请打包后从 DiskGuard.app 启动更新"
        case .authenticationRequired:
            return "访问私有仓库 Release 需要 GitHub 认证（请确认本机已登录 gh auth login 或设置 DISKGUARD_GITHUB_TOKEN）"
        case .httpError(let code):
            return "GitHub 更新接口返回异常状态码：HTTP \(code)"
        case .invalidReleasePayload(let detail):
            return "无法解析发布信息：\(detail)"
        case .noInstallableAsset:
            return "该 Release 中未找到可安装的 DiskGuard .zip 更新包"
        case .checksumMismatch(let expected, let actual):
            return "更新包 SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        case .extractionFailed(let detail):
            return "解压更新包失败：\(detail)"
        case .bundleValidationFailed(let detail):
            return "更新包校验失败：\(detail)"
        case .signatureVerificationFailed(let detail):
            return "新版本代码签名校验失败：\(detail)"
        case .launchHelperFailed(let detail):
            return "启动自动替换脚本失败：\(detail)"
        case .networkError(let detail):
            return "网络请求失败：\(detail)"
        }
    }
}

private final class NoAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if request.url?.host != "api.github.com" {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(stripped)
        } else {
            completionHandler(request)
        }
    }
}

public final class AppUpdater: Sendable {
    public let repoOwner: String
    public let repoName: String
    public let expectedBundleIdentifier: String

    private static let redirectDelegate = NoAuthRedirectDelegate()
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    public init(
        repoOwner: String = "caizhenyu666",
        repoName: String = "DiskGuard",
        expectedBundleIdentifier: String = "com.local.diskguard"
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    public static func currentAppVersion(bundle: Bundle = .main) -> SemVer {
        if let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let parsed = SemVer(raw) {
            return parsed
        }
        return SemVer(major: 0, minor: 0, patch: 0)
    }

    public static func currentBuildNumber(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    }

    public static func isRunningFromAppBundle(bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension.lowercased() == "app"
    }

    private struct GitHubReleasePayload: Decodable {
        struct Asset: Decodable {
            let id: Int
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let published_at: String?
        let assets: [Asset]
    }

    public static func parseReleaseJSON(_ data: Data) throws -> ReleaseInfo {
        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw UpdateError.invalidReleasePayload(error.localizedDescription)
        }

        guard let version = SemVer(payload.tag_name) else {
            throw UpdateError.invalidReleasePayload("无效版本号标签 \(payload.tag_name)")
        }

        let zipAsset = payload.assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip") && $0.name.localizedCaseInsensitiveContains("DiskGuard")
        }) ?? payload.assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip")
        })

        guard let zipAsset, let zipURL = URL(string: zipAsset.browser_download_url) else {
            throw UpdateError.noInstallableAsset
        }

        let shaAsset = payload.assets.first(where: {
            $0.name == "\(zipAsset.name).sha256"
        }) ?? payload.assets.first(where: {
            $0.name.lowercased().hasSuffix(".sha256") || $0.name == "SHA256SUMS"
        })

        let shaURL = shaAsset.flatMap { URL(string: $0.browser_download_url) }
        let title = (payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? payload.tag_name
        let notes = (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return ReleaseInfo(
            tagName: payload.tag_name,
            version: version,
            title: title,
            notes: notes,
            htmlURL: payload.html_url.flatMap(URL.init(string:)),
            assetName: zipAsset.name,
            assetID: zipAsset.id,
            browserDownloadURL: zipURL,
            sha256AssetName: shaAsset?.name,
            sha256AssetID: shaAsset?.id,
            sha256DownloadURL: shaURL,
            publishedAt: payload.published_at
        )
    }

    public static func parseSHA256Text(_ text: String, expectedFilename: String? = nil) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let candidate = tokens.first?.lowercased(), isValidSHA256Hex(candidate) else {
                continue
            }
            if let expectedFilename, tokens.count >= 2 {
                let fileToken = tokens.dropFirst().joined(separator: " ")
                let cleanFile = fileToken.hasPrefix("*") ? String(fileToken.dropFirst()) : fileToken
                if cleanFile == expectedFilename || URL(fileURLWithPath: cleanFile).lastPathComponent == expectedFilename {
                    return candidate
                }
                continue
            }
            return candidate
        }

        if expectedFilename != nil {
            return parseSHA256Text(text, expectedFilename: nil)
        }
        return nil
    }

    private static func isValidSHA256Hex(_ hex: String) -> Bool {
        guard hex.count == 64 else { return false }
        return hex.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    public static func resolveGitHubToken() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["DISKGUARD_GITHUB_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envToken.isEmpty {
            return envToken
        }

        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let result = DiskScanner.runCommandWithTimeout(
                executable: path,
                arguments: ["auth", "token"],
                timeoutSeconds: 3.0
            ), result.exitCode == 0 {
                let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    return token
                }
            }
        }
        return nil
    }

    public func checkForUpdates(
        currentVersion: SemVer = AppUpdater.currentAppVersion()
    ) async throws -> UpdateCheckOutcome {
        let token = await DiskScanner.runOnIOQueue { Self.resolveGitHubToken() }

        guard let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            throw UpdateError.invalidReleasePayload("无效仓库地址")
        }

        var request = URLRequest(url: apiURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DiskGuard/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.networkError("无效响应")
        }

        switch http.statusCode {
        case 200:
            let release = try Self.parseReleaseJSON(data)
            if release.version > currentVersion {
                return .updateAvailable(current: currentVersion, release: release)
            }
            return .upToDate(current: currentVersion, latest: release.version)
        case 401, 403:
            throw UpdateError.authenticationRequired
        case 404:
            if token == nil {
                throw UpdateError.authenticationRequired
            }
            return .noReleasesYet(current: currentVersion)
        default:
            throw UpdateError.httpError(http.statusCode)
        }
    }

    public func downloadAndPrepareUpdate(
        release: ReleaseInfo,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> PreparedUpdate {
        onProgress("正在准备下载 \(release.tagName)...")
        let token = await DiskScanner.runOnIOQueue { Self.resolveGitHubToken() }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("DiskGuardUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            let zipURL = tempDir.appendingPathComponent(release.assetName)
            let assetRequest = buildAssetRequest(
                assetID: release.assetID,
                browserDownloadURL: release.browserDownloadURL,
                token: token
            )

            onProgress("正在下载更新包 (\(release.assetName))...")
            let (downloadedTempURL, zipResponse) = try await Self.downloadSession.download(for: assetRequest)
            try validateHTTPResponse(zipResponse, token: token)
            if fm.fileExists(atPath: zipURL.path) {
                try fm.removeItem(at: zipURL)
            }
            try fm.moveItem(at: downloadedTempURL, to: zipURL)

            onProgress("正在校验 SHA-256 完整性...")
            let actualHash = try await DiskScanner.runOnIOQueue {
                Result { try Self.computeSHA256Hex(of: zipURL) }
            }.get()

            if let shaBrowserURL = release.sha256DownloadURL {
                let shaRequest = buildAssetRequest(
                    assetID: release.sha256AssetID,
                    browserDownloadURL: shaBrowserURL,
                    token: token
                )
                let (shaData, shaResponse) = try await Self.downloadSession.data(for: shaRequest)
                try validateHTTPResponse(shaResponse, token: token)
                let shaText = String(data: shaData, encoding: .utf8) ?? ""
                guard let expectedHash = Self.parseSHA256Text(shaText, expectedFilename: release.assetName) else {
                    throw UpdateError.bundleValidationFailed("无法解析 .sha256 校验文件")
                }
                guard expectedHash == actualHash else {
                    throw UpdateError.checksumMismatch(expected: expectedHash, actual: actualHash)
                }
            }

            onProgress("正在解压并验证应用签名...")
            let extractDir = tempDir.appendingPathComponent("extracted")
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let extractResult = await DiskScanner.runOnIOQueue {
                DiskScanner.runCommandWithTimeout(
                    executable: "/usr/bin/ditto",
                    arguments: ["-xk", zipURL.path, extractDir.path],
                    timeoutSeconds: 60.0
                )
            }
            guard let extractResult, extractResult.exitCode == 0 else {
                throw UpdateError.extractionFailed(extractResult?.output ?? "ditto 超时或执行失败")
            }

            let stagedAppURL = try locateAppBundle(in: extractDir)
            try validateBundleIdentifier(at: stagedAppURL)

            let signResult = await DiskScanner.runOnIOQueue {
                DiskScanner.runCommandWithTimeout(
                    executable: "/usr/bin/codesign",
                    arguments: ["--verify", "--deep", "--strict", stagedAppURL.path],
                    timeoutSeconds: 15.0
                )
            }
            guard let signResult, signResult.exitCode == 0 else {
                throw UpdateError.signatureVerificationFailed(signResult?.output ?? "codesign 验证失败")
            }

            return PreparedUpdate(
                release: release,
                stagedAppURL: stagedAppURL,
                tempDirectory: tempDir,
                verifiedSHA256: actualHash
            )
        } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
    }

    public func installAndRelaunch(
        prepared: PreparedUpdate,
        targetAppURL: URL = Bundle.main.bundleURL
    ) throws {
        let standardizedTarget = targetAppURL.standardizedFileURL
        guard standardizedTarget.pathExtension.lowercased() == "app" else {
            throw UpdateError.notRunningFromAppBundle
        }
        let parentDir = standardizedTarget.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw UpdateError.notRunningFromAppBundle
        }

        let scriptURL = prepared.tempDirectory.appendingPathComponent("apply-update.sh")
        let scriptContent = """
        #!/bin/sh
        set -eu
        PID="$1"
        TARGET_APP="$2"
        STAGED_APP="$3"
        TEMP_DIR="$4"
        BACKUP_APP="${TARGET_APP}.backup.$$"

        # Wait up to 15 seconds for current DiskGuard process to exit
        i=0
        while kill -0 "$PID" 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -ge 150 ]; then
                break
            fi
            sleep 0.1
        done

        if [ -e "$TARGET_APP" ]; then
            mv "$TARGET_APP" "$BACKUP_APP"
        fi

        if mv "$STAGED_APP" "$TARGET_APP"; then
            xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
            rm -rf "$BACKUP_APP" "$TEMP_DIR"
            open -n "$TARGET_APP"
            exit 0
        else
            if [ -e "$BACKUP_APP" ] && [ ! -e "$TARGET_APP" ]; then
                mv "$BACKUP_APP" "$TARGET_APP" || true
            fi
            exit 1
        fi
        """

        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                scriptURL.path,
                String(ProcessInfo.processInfo.processIdentifier),
                standardizedTarget.path,
                prepared.stagedAppURL.path,
                prepared.tempDirectory.path
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            throw UpdateError.launchHelperFailed(error.localizedDescription)
        }
    }

    private func buildAssetRequest(
        assetID: Int?,
        browserDownloadURL: URL,
        token: String?
    ) -> URLRequest {
        if let token,
           let assetID,
           let apiAssetURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/assets/\(assetID)") {
            var req = URLRequest(url: apiAssetURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("DiskGuard", forHTTPHeaderField: "User-Agent")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return req
        }

        var req = URLRequest(url: browserDownloadURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("DiskGuard", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func validateHTTPResponse(_ response: URLResponse, token: String?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.networkError("无效下载响应")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw UpdateError.authenticationRequired
        case 404:
            if token == nil {
                throw UpdateError.authenticationRequired
            }
            throw UpdateError.httpError(404)
        default:
            throw UpdateError.httpError(http.statusCode)
        }
    }

    private func locateAppBundle(in extractDir: URL) throws -> URL {
        let direct = extractDir.appendingPathComponent("DiskGuard.app")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDir), isDir.boolValue {
            return direct
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if let found = children.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return found
        }
        throw UpdateError.bundleValidationFailed("压缩包内未找到 DiskGuard.app")
    }

    private func validateBundleIdentifier(at appURL: URL) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL),
              let bundleID = dict["CFBundleIdentifier"] as? String else {
            throw UpdateError.bundleValidationFailed("无法读取新版本 Info.plist")
        }
        guard bundleID == expectedBundleIdentifier else {
            throw UpdateError.bundleValidationFailed("Bundle ID 不匹配（\(bundleID)）")
        }
    }

    private static func computeSHA256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1_048_576
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
