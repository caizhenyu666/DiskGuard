import Foundation
import Testing
@testable import DiskGuardCore

@Suite("DiskScanner & Rule Filter Tests")
struct DiskScannerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Hard links sharing an inode are counted only once")
    func hardLinkInodeDeduplication() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.bin")
        let fileB = dir.appendingPathComponent("b.bin")
        try Data(repeating: 0x5A, count: 65_536).write(to: fileA)
        try FileManager.default.linkItem(at: fileA, to: fileB)

        let singleSize = DiskScanner.directorySize(at: dir)
        let attrs = try fileA.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let expectedOneFile = Int64(attrs.totalFileAllocatedSize ?? attrs.fileAllocatedSize ?? 65_536)

        #expect(singleSize == expectedOneFile)
        #expect(singleSize > 0)
    }

    @Test("Conda pkgs filter selects only writable .tar.bz2 and .conda archives")
    func condaArchiveFilter() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pkg1 = dir.appendingPathComponent("numpy-1.26.conda")
        let pkg2 = dir.appendingPathComponent("scipy-1.11.tar.bz2")
        let extractedDir = dir.appendingPathComponent("numpy-1.26")
        let metaFile = dir.appendingPathComponent("urls.txt")

        try Data("conda".utf8).write(to: pkg1)
        try Data("bz2".utf8).write(to: pkg2)
        try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try Data("extracted".utf8).write(to: extractedDir.appendingPathComponent("lib.so"))
        try Data("urls".utf8).write(to: metaFile)

        let filtered = DiskScanner.filterCondaArchives(in: dir)
        let names = Set(filtered.map { $0.lastPathComponent })
        #expect(names == Set(["numpy-1.26.conda", "scipy-1.11.tar.bz2"]))
    }

    @Test("Unity project discovery and UnityLockfile lock detection")
    func unityProjectDiscoveryAndLocking() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }

        let openProj = home.appendingPathComponent("GameOpen")
        let closedProj = home.appendingPathComponent("GameClosed")
        let regularDir = home.appendingPathComponent("Notes")

        for proj in [openProj, closedProj] {
            try FileManager.default.createDirectory(at: proj.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: proj.appendingPathComponent("ProjectSettings"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: proj.appendingPathComponent("Temp"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: regularDir, withIntermediateDirectories: true)
        try Data("lock".utf8).write(to: openProj.appendingPathComponent("Temp/UnityLockfile"))

        let discovered = DiskScanner.discoverUnityProjects(in: home)
        let names = Set(discovered.map { $0.lastPathComponent })
        #expect(names == Set(["GameOpen", "GameClosed"]))
        #expect(DiskScanner.isUnityProjectLocked(openProj) == true)
        #expect(DiskScanner.isUnityProjectLocked(closedProj) == false)
    }

    @Test("Downloads filter selects only .dmg and .pkg older than 7 days")
    func downloadsOldInstallerFilter() throws {
        let downloads = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: downloads) }

        let now = Date()
        let oldDate = now.addingTimeInterval(-10 * 86_400)
        let recentDate = now.addingTimeInterval(-2 * 86_400)

        let oldDmg = downloads.appendingPathComponent("OldApp.dmg")
        let oldPkg = downloads.appendingPathComponent("OldTool.pkg")
        let recentDmg = downloads.appendingPathComponent("NewApp.dmg")
        let oldPdf = downloads.appendingPathComponent("Report.pdf")
        let oldZip = downloads.appendingPathComponent("Archive.zip")

        for url in [oldDmg, oldPkg, recentDmg, oldPdf, oldZip] {
            try Data("payload".utf8).write(to: url)
        }
        for url in [oldDmg, oldPkg, oldPdf, oldZip] {
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: recentDmg.path)

        let matched = DiskScanner.filterOldDownloads(in: downloads, now: now, olderThanDays: 7)
        let names = Set(matched.map { $0.url.lastPathComponent })
        #expect(names == Set(["OldApp.dmg", "OldTool.pkg"]))
    }

    @Test("listImmediateEntries includes dotfiles, skips .DS_Store, and marks directories & symlinks")
    func listImmediateEntriesBehavior() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dotGit = dir.appendingPathComponent(".git")
        let subdir = dir.appendingPathComponent("SubFolder")
        let normalFile = dir.appendingPathComponent("notes.txt")
        let dsStore = dir.appendingPathComponent(".DS_Store")
        let symlink = dir.appendingPathComponent("alias-link")

        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: normalFile)
        try Data("ds".utf8).write(to: dsStore)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: subdir)

        let entries = try DiskScanner.listImmediateEntries(at: dir)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(byName[".DS_Store"] == nil)
        #expect(byName[".git"]?.isDirectory == true)
        #expect(byName[".git"]?.isHidden == true)
        #expect(byName["SubFolder"]?.isDirectory == true)
        #expect(byName["SubFolder"]?.sizeBytes == nil)
        #expect(byName["notes.txt"]?.isDirectory == false)
        #expect(byName["notes.txt"]?.sizeBytes != nil)
        #expect(byName["alias-link"]?.isSymbolicLink == true)
        #expect(byName["alias-link"]?.isDirectory == false)
    }

    @Test("UserPreferences persists appearance, collapsed tiers, filter, and log drawer across instances")
    func userPreferencesPersistence() {
        let suite = "com.local.diskguard.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let writer = UserPreferences(suiteName: suite)
        writer.appearanceMode = .dark
        writer.collapsedTiers = [.readOnly, .caution]
        writer.activeFilterRawValue = "safe"
        writer.isLogDrawerExpanded = true

        let reader = UserPreferences(suiteName: suite)
        #expect(reader.appearanceMode == .dark)
        #expect(reader.collapsedTiers == Set([.readOnly, .caution]))
        #expect(reader.activeFilterRawValue == "safe")
        #expect(reader.isLogDrawerExpanded == true)
    }
}
