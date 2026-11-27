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

    private static func referenceEnumeratorSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileResourceIdentifierKey
        ]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return 0
        }
        var seenInodes = Set<Data>()
        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            guard let vals = try? itemURL.resourceValues(forKeys: Set(keys)) else { continue }
            if vals.isSymbolicLink == true {
                continue
            }
            guard vals.isRegularFile == true else { continue }
            if let identifier = vals.fileResourceIdentifier as? Data {
                if !seenInodes.insert(identifier).inserted { continue }
            }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? 0)
        }
        return total
    }

    @Test("FastDirectorySizer matches reference FileManager enumerator on mixed tree with hardlinks and symlinks")
    func fastDirectorySizerMatchesReferenceEnumerator() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let subA = root.appendingPathComponent("a/b/c")
        let subB = root.appendingPathComponent("sibling")
        let emptyDir = root.appendingPathComponent("empty")
        let outsideTarget = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let f1 = subA.appendingPathComponent("one.bin")
        let f2 = root.appendingPathComponent(".dotfile")
        let f3 = subB.appendingPathComponent("three.bin")
        try Data(repeating: 0x11, count: 16_384).write(to: f1)
        try Data(repeating: 0x22, count: 32_768).write(to: f2)
        try Data(repeating: 0x33, count: 24_576).write(to: f3)

        // Hardlink in same directory and across sibling directory
        try FileManager.default.linkItem(at: f1, to: subA.appendingPathComponent("one-hardlink.bin"))
        try FileManager.default.linkItem(at: f1, to: subB.appendingPathComponent("one-crosslink.bin"))

        // Symlink to outside file & outside directory (must NOT be followed)
        let outsideBig = outsideTarget.appendingPathComponent("big.bin")
        try Data(repeating: 0x99, count: 262_144).write(to: outsideBig)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-file"), withDestinationURL: outsideBig)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-to-dir"), withDestinationURL: outsideTarget)

        let fastSize = FastDirectorySizer.directorySize(at: root)
        let refSize = Self.referenceEnumeratorSize(at: root)

        #expect(fastSize == refSize)
        #expect(fastSize == 73_728)
        #expect(fastSize < 262_144)
        #expect(FastDirectorySizer.directorySize(at: root.appendingPathComponent("link-to-dir")) == 0)
        #expect(FastDirectorySizer.directorySize(at: f1) == FastDirectorySizer.directorySize(at: f1))
    }

    @Test("DirectorySizeCache records up to cacheDepth and invalidates targets, descendants, and ancestors")
    func directorySizeCacheDepthAndInvalidation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let d1 = root.appendingPathComponent("sub1")
        let d2 = d1.appendingPathComponent("sub2")
        let d3 = d2.appendingPathComponent("sub3")
        let sibling = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: d3, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        try Data(repeating: 0xAA, count: 8_192).write(to: d3.appendingPathComponent("deep.bin"))
        try Data(repeating: 0xBB, count: 8_192).write(to: sibling.appendingPathComponent("side.bin"))

        let cache = DirectorySizeCache()
        let total = FastDirectorySizer.directorySize(at: root, cache: cache, cacheDepth: 2)

        #expect(total > 0)
        #expect(cache.size(for: root) == total)
        #expect(cache.size(for: d1) != nil)
        #expect(cache.size(for: d2) != nil)
        #expect(cache.size(for: d3) == nil)
        #expect(cache.size(for: sibling) != nil)

        cache.invalidate(prefixPath: d2.path)

        #expect(cache.size(for: d2) == nil)
        #expect(cache.size(for: d1) == nil)
        #expect(cache.size(for: root) == nil)
        #expect(cache.size(for: sibling) != nil)
    }

    @Test("AtomicCancelFlag aborts FastDirectorySizer without populating cache")
    func atomicCancelFlagAbortsWithoutCaching() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x44, count: 16_384).write(to: root.appendingPathComponent("data.bin"))
        let flag = AtomicCancelFlag()
        flag.cancel()

        let cache = DirectorySizeCache()
        let size = FastDirectorySizer.directorySize(at: root, cache: cache, cacheDepth: 3, cancelFlag: flag)

        #expect(size == 0)
        #expect(cache.size(for: root) == nil)
    }

    private final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var batches: [[ScanItem]] = []

        func append(_ items: [ScanItem]) {
            lock.lock()
            batches.append(items)
            lock.unlock()
        }
    }

    @Test("DiskScanner.scanAll streams batches in phases and deduplicates sorted items")
    func scanAllStreamsBatchesAndDeduplicates() async throws {
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let apps = sandbox.appendingPathComponent("Apps")
        let sysLib = sandbox.appendingPathComponent("SysLib")
        let conda = sandbox.appendingPathComponent("conda")

        let homebrew = home.appendingPathComponent("Library/Caches/Homebrew")
        let npmCache = home.appendingPathComponent(".npm/_cacache")
        let trash = home.appendingPathComponent(".Trash")
        let downloads = home.appendingPathComponent("Downloads")
        let appSupport = home.appendingPathComponent("Library/Application Support")

        for dir in [homebrew, npmCache, trash, downloads, appSupport, apps, sysLib, conda] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try Data(repeating: 0x01, count: 1_200_000).write(to: homebrew.appendingPathComponent("pkg.tar.gz"))
        try Data(repeating: 0x02, count: 1_400_000).write(to: npmCache.appendingPathComponent("index.bin"))
        try Data(repeating: 0x03, count: 1_100_000).write(to: trash.appendingPathComponent("old.bin"))

        let scanner = DiskScanner(
            homeDirectory: home,
            applicationsDirectory: apps,
            systemLibraryDirectory: sysLib,
            minicondaPkgsDirectory: conda
        )
        let cache = DirectorySizeCache()
        let collector = BatchCollector()

        let result = await scanner.scanAll(
            sizeCache: cache,
            onProgress: { _ in },
            onBatch: { batch in
                collector.append(batch)
            }
        )

        #expect(!collector.batches.isEmpty)
        let ids = result.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("tier1.cache.Homebrew"))
        #expect(ids.contains("tier1.npm._cacache"))
        #expect(ids.contains("tier3.trash"))

        // Verify tier ordering: safe before readOnly
        if let safeIdx = result.items.firstIndex(where: { $0.id == "tier1.cache.Homebrew" }),
           let trashIdx = result.items.firstIndex(where: { $0.id == "tier3.trash" }) {
            #expect(safeIdx < trashIdx)
        }
    }

    @Test("DiskScanner.refreshTargets incrementally updates removed, shrunken, and trash items")
    func refreshTargetsUpdatesIncrementally() async throws {
        let sandbox = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let apps = sandbox.appendingPathComponent("Apps")
        let sysLib = sandbox.appendingPathComponent("SysLib")
        let conda = sandbox.appendingPathComponent("conda")

        let homebrew = home.appendingPathComponent("Library/Caches/Homebrew")
        let npmCache = home.appendingPathComponent(".npm/_cacache")
        let trash = home.appendingPathComponent(".Trash")
        let downloads = home.appendingPathComponent("Downloads")
        let appSupport = home.appendingPathComponent("Library/Application Support")

        for dir in [homebrew, npmCache, trash, downloads, appSupport, apps, sysLib, conda] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try Data(repeating: 0x01, count: 1_200_000).write(to: homebrew.appendingPathComponent("pkg.tar.gz"))
        let npmA = npmCache.appendingPathComponent("a.bin")
        let npmB = npmCache.appendingPathComponent("b.bin")
        try Data(repeating: 0x02, count: 1_200_000).write(to: npmA)
        try Data(repeating: 0x02, count: 1_200_000).write(to: npmB)
        try Data(repeating: 0x03, count: 1_100_000).write(to: trash.appendingPathComponent("old.bin"))

        let scanner = DiskScanner(
            homeDirectory: home,
            applicationsDirectory: apps,
            systemLibraryDirectory: sysLib,
            minicondaPkgsDirectory: conda
        )
        let cache = DirectorySizeCache()

        let initial = await scanner.scanAll(sizeCache: cache, onProgress: { _ in })
        let initialNpm = try #require(initial.items.first(where: { $0.id == "tier1.npm._cacache" }))
        let initialTrash = try #require(initial.items.first(where: { $0.id == "tier3.trash" }))

        // Mutate disk: delete Homebrew, delete one npm cache file, add a file to Trash
        try FileManager.default.removeItem(at: homebrew)
        try FileManager.default.removeItem(at: npmB)
        try Data(repeating: 0x04, count: 1_300_000).write(to: trash.appendingPathComponent("more.bin"))

        let refreshed = await scanner.refreshTargets(
            existingItems: initial.items,
            affectedPaths: [homebrew, npmCache],
            includeTrash: true,
            fdaStatus: .granted,
            sizeCache: cache
        )

        #expect(refreshed.items.first(where: { $0.id == "tier1.cache.Homebrew" }) == nil)
        let updatedNpm = try #require(refreshed.items.first(where: { $0.id == "tier1.npm._cacache" }))
        let updatedTrash = try #require(refreshed.items.first(where: { $0.id == "tier3.trash" }))

        #expect(updatedNpm.sizeBytes < initialNpm.sizeBytes)
        #expect(updatedNpm.sizeBytes >= 1_000_000)
        #expect(updatedTrash.sizeBytes > initialTrash.sizeBytes)
    }
}
