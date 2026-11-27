import Foundation
import Testing
@testable import DiskGuardCore

@Suite("SafetyGuard Security Tests")
struct SafetyGuardTests {
    private func makeSandbox() throws -> (root: URL, home: URL, guardEngine: SafetyGuard) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskGuardTests-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (base, home, SafetyGuard(homeDirectory: home))
    }

    private func cleanupSandbox(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Rejects read-only tier items")
    func rejectsReadOnlyTier() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let caches = home.appendingPathComponent("Library/Caches")
        let target = caches.appendingPathComponent("SomeApp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        #expect(throws: GuardRejection.readOnlyTier) {
            try safety.validate(
                target: target,
                allowedRoot: caches,
                tier: .readOnly,
                cleanupMode: .trashItem,
                lockReason: nil,
                allowWorktreePointer: false
            )
        }
    }

    @Test("Rejects locked items")
    func rejectsLockedItem() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let caches = home.appendingPathComponent("Library/Caches")
        let target = caches.appendingPathComponent("UnityTemp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        #expect(throws: GuardRejection.lockedItem("Unity 正在运行")) {
            try safety.validate(
                target: target,
                allowedRoot: caches,
                tier: .safe,
                cleanupMode: .trashItem,
                lockReason: "Unity 正在运行",
                allowWorktreePointer: false
            )
        }
    }

    @Test("Rejects protected system and user directories")
    func rejectsProtectedDirectories() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let protected = [
            "/",
            "/System",
            "/Applications",
            home.path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent(".ssh").path,
            home.appendingPathComponent("Library/Keychains").path,
            home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat").path
        ]

        for path in protected {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let parent = url.deletingLastPathComponent()
            do {
                _ = try safety.validate(
                    target: url,
                    allowedRoot: parent,
                    tier: .safe,
                    cleanupMode: .trashItem,
                    lockReason: nil,
                    allowWorktreePointer: false
                )
                Issue.record("Expected protected path rejection for \(path)")
            } catch is GuardRejection {
                // Expected
            }
        }
    }

    @Test("Rejects path traversal outside allowedRoot")
    func rejectsPathTraversal() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let caches = home.appendingPathComponent("Library/Caches")
        let docs = home.appendingPathComponent("Documents")
        let secret = docs.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("important".utf8).write(to: secret)

        let traversal = caches.appendingPathComponent("../../Documents/secret.txt")
        do {
            _ = try safety.validate(
                target: traversal,
                allowedRoot: caches,
                tier: .safe,
                cleanupMode: .trashItem,
                lockReason: nil,
                allowWorktreePointer: false
            )
            Issue.record("Expected traversal rejection")
        } catch let rejection as GuardRejection {
            switch rejection {
            case .outsideAllowedRoot, .protectedPath:
                break
            default:
                Issue.record("Unexpected rejection: \(rejection)")
            }
        }
    }

    @Test("Rejects symlinks without touching target")
    func rejectsSymbolicLinks() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let caches = home.appendingPathComponent("Library/Caches")
        let docs = home.appendingPathComponent("Documents")
        let secret = docs.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("keep-me".utf8).write(to: secret)

        let link = caches.appendingPathComponent("evil-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        #expect(throws: GuardRejection.symbolicLinkRejected(link.standardizedFileURL.path)) {
            try safety.validate(
                target: link,
                allowedRoot: caches,
                tier: .safe,
                cleanupMode: .trashItem,
                lockReason: nil,
                allowWorktreePointer: false
            )
        }
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test("Rejects directories containing a .git repository directory even if allowWorktreePointer is true")
    func rejectsFullGitRepository() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let worktrees = home.appendingPathComponent(".codex/worktrees")
        let repo = worktrees.appendingPathComponent("backup-repo")
        let dotGitDir = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGitDir, withIntermediateDirectories: true)

        #expect(throws: GuardRejection.containsGitRepository(repo.resolvingSymlinksInPath().standardizedFileURL.path)) {
            try safety.validate(
                target: repo,
                allowedRoot: worktrees,
                tier: .caution,
                cleanupMode: .trashItem,
                lockReason: nil,
                allowWorktreePointer: true
            )
        }
    }

    @Test("Allows clean Codex worktree with .git pointer file, rejects if outside .codex/worktrees")
    func codexWorktreePointerValidation() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let worktrees = home.appendingPathComponent(".codex/worktrees")
        let wt1 = worktrees.appendingPathComponent("wt1")
        try FileManager.default.createDirectory(at: wt1, withIntermediateDirectories: true)
        try Data("gitdir: /some/repo/.git/worktrees/wt1\n".utf8).write(to: wt1.appendingPathComponent(".git"))

        let validated = try safety.validate(
            target: wt1,
            allowedRoot: worktrees,
            tier: .caution,
            cleanupMode: .trashItem,
            lockReason: nil,
            allowWorktreePointer: true
        )
        #expect(validated.lastPathComponent == "wt1")

        let otherRoot = home.appendingPathComponent("Projects")
        let otherWt = otherRoot.appendingPathComponent("wt2")
        try FileManager.default.createDirectory(at: otherWt, withIntermediateDirectories: true)
        try Data("gitdir: /some/repo/.git/worktrees/wt2\n".utf8).write(to: otherWt.appendingPathComponent(".git"))

        #expect(throws: GuardRejection.containsGitRepository(otherWt.resolvingSymlinksInPath().standardizedFileURL.path)) {
            try safety.validate(
                target: otherWt,
                allowedRoot: otherRoot,
                tier: .caution,
                cleanupMode: .trashItem,
                lockReason: nil,
                allowWorktreePointer: true
            )
        }
    }

    @Test("Real FileManager.trashItem moves items safely and cleans up test artifact")
    func realTrashItemAndChildrenWork() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let caches = home.appendingPathComponent("Library/Caches")
        let appCache = caches.appendingPathComponent("DemoApp")
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        let f1 = appCache.appendingPathComponent("a.bin")
        let f2 = appCache.appendingPathComponent("b.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: f1)
        try Data(repeating: 0xCD, count: 4096).write(to: f2)

        // Link inside appCache should be skipped safely while real children are trashed
        let docsFile = home.appendingPathComponent("Documents/keep.txt")
        try FileManager.default.createDirectory(at: docsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: docsFile)
        try FileManager.default.createSymbolicLink(at: appCache.appendingPathComponent("link"), withDestinationURL: docsFile)

        let item = ScanItem(
            id: "demo-cache",
            title: "DemoApp 缓存",
            subtitle: "测试缓存",
            categoryIcon: "archivebox",
            tier: .safe,
            cleanupMode: .trashChildren,
            allowedRoot: caches,
            targets: [appCache],
            sizeBytes: 8192
        )

        var trashedForCleanup: [URL] = []
        let report = safety.trash(
            item: item,
            trashHandler: { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                if let u = resultingURL as URL? {
                    trashedForCleanup.append(u)
                }
                return resultingURL as URL?
            }
        )
        defer {
            for u in trashedForCleanup {
                try? FileManager.default.removeItem(at: u)
            }
        }

        #expect(report.trashedCount == 2)
        #expect(report.skippedCount == 1) // symlink skipped
        #expect(!FileManager.default.fileExists(atPath: f1.path))
        #expect(!FileManager.default.fileExists(atPath: f2.path))
        #expect(FileManager.default.fileExists(atPath: docsFile.path))
        #expect(trashedForCleanup.count == 2)
    }

    @Test("validateTrashDeletion rejects paths outside ~/.Trash and ~/.Trash itself")
    func validateTrashDeletionRejectsOutsideTrash() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let trash = home.appendingPathComponent(".Trash")
        let docs = home.appendingPathComponent("Documents")
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let docFile = docs.appendingPathComponent("file.txt")
        let cacheFile = caches.appendingPathComponent("foo")
        try Data("doc".utf8).write(to: docFile)
        try Data("cache".utf8).write(to: cacheFile)

        let disallowed = [
            docFile,
            cacheFile,
            trash,
            trash.appendingPathComponent("../Documents/file.txt")
        ]

        for url in disallowed {
            do {
                _ = try safety.validateTrashDeletion(target: url)
                Issue.record("Expected rejection for \(url.path)")
            } catch is GuardRejection {
                // Expected
            }
        }
    }

    @Test("permanentlyDeleteFromTrash removes real files & symlinks inside ~/.Trash without deleting symlink target")
    func emptyTrashSafelyHandlesSymlinksAndFiles() throws {
        let (sandbox, home, safety) = try makeSandbox()
        defer { cleanupSandbox(sandbox) }

        let trash = home.appendingPathComponent(".Trash")
        let docs = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        let secret = docs.appendingPathComponent("secret.txt")
        try Data("keep-me-safe".utf8).write(to: secret)

        let junk = trash.appendingPathComponent("junk.bin")
        try Data(repeating: 0x11, count: 4096).write(to: junk)

        let symlinkInTrash = trash.appendingPathComponent("link-to-secret")
        try FileManager.default.createSymbolicLink(at: symlinkInTrash, withDestinationURL: secret)

        let report = safety.emptyTrash()
        #expect(report.trashedCount == 2)
        #expect(report.skippedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: junk.path))
        var st = stat()
        #expect(lstat(symlinkInTrash.path, &st) != 0)
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }
}
