import Foundation
import Testing
@testable import DiskGuardCore

@Suite("AppUpdater & SemVer Tests")
struct AppUpdaterTests {
    @Test("SemVer parses standard, two-part, and pre-release tags and rejects invalid strings")
    func semVerParsingAndOrdering() throws {
        let v1 = try #require(SemVer("1.0.0"))
        let v2 = try #require(SemVer("v1.0.1"))
        let v3 = try #require(SemVer("V1.2"))
        let v4 = try #require(SemVer("v1.10.0-beta.2+build9"))

        #expect(v1.description == "1.0.0")
        #expect(v1.displayTag == "v1.0.0")
        #expect(v3 == SemVer(major: 1, minor: 2, patch: 0))
        #expect(v4 == SemVer(major: 1, minor: 10, patch: 0))

        #expect(v1 < v2)
        #expect(v2 < v3)
        #expect(v3 < v4)
        #expect(v4 < SemVer(major: 2, minor: 0, patch: 0))

        #expect(SemVer("") == nil)
        #expect(SemVer("v") == nil)
        #expect(SemVer("1") == nil)
        #expect(SemVer("1.2.3.4") == nil)
        #expect(SemVer("1.x.0") == nil)
        #expect(SemVer("-1.0.0") == nil)
    }

    @Test("parseReleaseJSON extracts zip asset, sha256 asset, and release metadata")
    func parseReleaseJSONSuccessAndMissingZip() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "name": "DiskGuard v1.2.0",
          "body": "- 扫描提速 5 倍\\n- 新增应用内自动更新",
          "html_url": "https://github.com/caizhenyu666/DiskGuard/releases/tag/v1.2.0",
          "published_at": "2026-11-27T12:00:00Z",
          "assets": [
            {
              "id": 1001,
              "name": "DiskGuard-v1.2.0.zip",
              "browser_download_url": "https://github.com/caizhenyu666/DiskGuard/releases/download/v1.2.0/DiskGuard-v1.2.0.zip"
            },
            {
              "id": 1002,
              "name": "DiskGuard-v1.2.0.zip.sha256",
              "browser_download_url": "https://github.com/caizhenyu666/DiskGuard/releases/download/v1.2.0/DiskGuard-v1.2.0.zip.sha256"
            }
          ]
        }
        """

        let release = try AppUpdater.parseReleaseJSON(Data(json.utf8))
        #expect(release.tagName == "v1.2.0")
        #expect(release.version == SemVer(major: 1, minor: 2, patch: 0))
        #expect(release.title == "DiskGuard v1.2.0")
        #expect(release.notes.contains("扫描提速 5 倍"))
        #expect(release.assetID == 1001)
        #expect(release.assetName == "DiskGuard-v1.2.0.zip")
        #expect(release.sha256AssetID == 1002)
        #expect(release.sha256AssetName == "DiskGuard-v1.2.0.zip.sha256")

        let noZipJson = """
        {
          "tag_name": "v1.2.0",
          "name": "No Zip",
          "assets": [
            {
              "id": 1003,
              "name": "notes.txt",
              "browser_download_url": "https://example.com/notes.txt"
            }
          ]
        }
        """
        #expect(throws: UpdateError.noInstallableAsset) {
            _ = try AppUpdater.parseReleaseJSON(Data(noZipJson.utf8))
        }
    }

    @Test("parseSHA256Text parses shasum format, bare hex, and rejects malformed inputs")
    func parseSHA256TextBehavior() {
        let validHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let upperHex = validHex.uppercased()

        let shasumOutput = "\(upperHex)  DiskGuard-v1.2.0.zip\n"
        #expect(AppUpdater.parseSHA256Text(shasumOutput, expectedFilename: "DiskGuard-v1.2.0.zip") == validHex)
        #expect(AppUpdater.parseSHA256Text("  \(validHex) \n") == validHex)
        #expect(AppUpdater.parseSHA256Text("not-a-sha256") == nil)
        #expect(AppUpdater.parseSHA256Text("abcd1234  DiskGuard-v1.2.0.zip") == nil)
    }

    @Test("helperScriptContent waits for PID, escalates to TERM/KILL if stuck, swaps atomically, and launches without -n")
    func helperScriptContentBehavior() {
        let script = AppUpdater.helperScriptContent()
        #expect(script.contains("kill -0 \"$PID\""))
        #expect(script.contains("kill -TERM \"$PID\""))
        #expect(script.contains("kill -KILL \"$PID\""))
        #expect(script.contains("mv \"$TARGET_APP\" \"$BACKUP_APP\""))
        #expect(script.contains("mv \"$STAGED_APP\" \"$TARGET_APP\""))
        #expect(script.contains("open \"$TARGET_APP\""))
        #expect(!script.contains("open -n "))
    }
}
