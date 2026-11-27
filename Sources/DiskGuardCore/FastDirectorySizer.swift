import Foundation
import Darwin

public final class AtomicCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

public final class DirectorySizeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Int64] = [:]

    public init() {}

    private static func normalize(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    public func size(for url: URL) -> Int64? {
        size(forPath: url.standardizedFileURL.path)
    }

    public func size(forPath path: String) -> Int64? {
        let key = Self.normalize(path)
        lock.lock()
        let value = entries[key]
        lock.unlock()
        return value
    }

    public func setSize(_ bytes: Int64, forPath path: String) {
        let key = Self.normalize(path)
        lock.lock()
        entries[key] = bytes
        lock.unlock()
    }

    public func merge(_ map: [String: Int64]) {
        guard !map.isEmpty else { return }
        lock.lock()
        for (k, v) in map {
            entries[Self.normalize(k)] = v
        }
        lock.unlock()
    }

    public func invalidate(prefixPath: String) {
        let normalized = Self.normalize(prefixPath)
        lock.lock()
        if normalized == "/" {
            entries.removeAll()
            lock.unlock()
            return
        }
        let childPrefix = normalized + "/"
        let keysToRemove = entries.keys.filter { key in
            if key == normalized || key.hasPrefix(childPrefix) {
                return true
            }
            if key == "/" {
                return true
            }
            return normalized.hasPrefix(key + "/")
        }
        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

public enum FastDirectorySizer {
    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    private struct DirFrame {
        let path: String
        let depth: Int
        var totalBytes: Int64
        let subdirs: [String]
        var nextIndex: Int
    }

    private static let bulkBufferSize = 65_536

    public static func directorySize(
        at url: URL,
        cache: DirectorySizeCache? = nil,
        cacheDepth: Int = 3,
        cancelFlag: AtomicCancelFlag? = nil
    ) -> Int64 {
        if cancelFlag?.isCancelled == true {
            return 0
        }

        let rootPath = url.standardizedFileURL.path
        if let cached = cache?.size(forPath: rootPath) {
            return cached
        }

        var st = stat()
        guard lstat(rootPath, &st) == 0 else {
            return 0
        }

        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            return 0
        }
        if mode != S_IFDIR {
            if mode == S_IFREG {
                return singleFileAllocatedSize(path: rootPath, fallbackStat: st)
            }
            return 0
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        attrList.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATAALLOCSIZE)

        var seenInodes = Set<InodeKey>()
        var localCache: [String: Int64] = [:]

        let rootRead = readDirectory(
            path: rootPath,
            attrList: &attrList,
            buffer: buffer,
            seenInodes: &seenInodes,
            cancelFlag: cancelFlag
        )
        if rootRead.cancelled || cancelFlag?.isCancelled == true {
            return 0
        }

        var stack: [DirFrame] = [
            DirFrame(
                path: rootPath,
                depth: 0,
                totalBytes: rootRead.fileBytes,
                subdirs: rootRead.subdirs,
                nextIndex: 0
            )
        ]

        while !stack.isEmpty {
            if cancelFlag?.isCancelled == true {
                return 0
            }

            let topIdx = stack.count - 1
            if stack[topIdx].nextIndex < stack[topIdx].subdirs.count {
                let childPath = stack[topIdx].subdirs[stack[topIdx].nextIndex]
                stack[topIdx].nextIndex += 1
                let childDepth = stack[topIdx].depth + 1

                if let cachedChild = cache?.size(forPath: childPath) {
                    stack[topIdx].totalBytes += cachedChild
                    continue
                }

                let childRead = readDirectory(
                    path: childPath,
                    attrList: &attrList,
                    buffer: buffer,
                    seenInodes: &seenInodes,
                    cancelFlag: cancelFlag
                )
                if childRead.cancelled || cancelFlag?.isCancelled == true {
                    return 0
                }

                stack.append(
                    DirFrame(
                        path: childPath,
                        depth: childDepth,
                        totalBytes: childRead.fileBytes,
                        subdirs: childRead.subdirs,
                        nextIndex: 0
                    )
                )
            } else {
                let completed = stack.removeLast()
                if cache != nil && completed.depth <= cacheDepth {
                    localCache[completed.path] = completed.totalBytes
                }
                if let parentIdx = stack.indices.last {
                    stack[parentIdx].totalBytes += completed.totalBytes
                } else {
                    if let cache {
                        cache.merge(localCache)
                    }
                    return completed.totalBytes
                }
            }
        }

        return 0
    }

    private static func singleFileAllocatedSize(path: String, fallbackStat: stat) -> Int64 {
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrList.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATAALLOCSIZE)

        let bufSize = 64
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        let rc = path.withCString { cPath in
            getattrlist(cPath, &attrList, buf, bufSize, UInt32(FSOPT_NOFOLLOW))
        }
        if rc == 0 {
            let entryLen = buf.loadUnaligned(as: UInt32.self)
            if entryLen >= 24 && Int(entryLen) <= bufSize {
                let returned = (buf + 4).loadUnaligned(as: attribute_set_t.self)
                let ptr = buf + 4 + MemoryLayout<attribute_set_t>.size
                if (returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0 {
                    let alloc = ptr.loadUnaligned(as: Int64.self)
                    return max(0, alloc)
                }
                if (returned.fileattr & attrgroup_t(ATTR_FILE_DATAALLOCSIZE)) != 0 {
                    let dataAlloc = ptr.loadUnaligned(as: Int64.self)
                    return max(0, dataAlloc)
                }
            }
        }

        return max(0, Int64(fallbackStat.st_blocks) * 512)
    }

    private static func readDirectory(
        path: String,
        attrList: inout attrlist,
        buffer: UnsafeMutableRawPointer,
        seenInodes: inout Set<InodeKey>,
        cancelFlag: AtomicCancelFlag?
    ) -> (fileBytes: Int64, subdirs: [String], cancelled: Bool) {
        let fd = path.withCString { cPath in
            open(cPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            return (0, [], false)
        }
        defer { close(fd) }

        var fileBytes: Int64 = 0
        var subdirs: [String] = []
        let cmnReturnedSize = MemoryLayout<attribute_set_t>.size
        let attrRefSize = MemoryLayout<attrreference_t>.size
        let prefixPath = path == "/" ? "/" : path + "/"

        while true {
            if cancelFlag?.isCancelled == true {
                return (0, [], true)
            }

            let count = getattrlistbulk(fd, &attrList, buffer, bulkBufferSize, UInt64(FSOPT_NOFOLLOW))
            if count <= 0 {
                break
            }

            var entryOffset = 0
            for _ in 0..<Int(count) {
                guard entryOffset + 4 + cmnReturnedSize <= bulkBufferSize else {
                    break
                }
                let entryPtr = buffer + entryOffset
                let entryLen = Int(entryPtr.loadUnaligned(as: UInt32.self))
                guard entryLen >= 4 + cmnReturnedSize, entryOffset + entryLen <= bulkBufferSize else {
                    break
                }
                let entryEnd = entryPtr + entryLen
                entryOffset += entryLen

                var fieldPtr = entryPtr + 4
                let returned = fieldPtr.loadUnaligned(as: attribute_set_t.self)
                fieldPtr += cmnReturnedSize

                let cmn = returned.commonattr
                let file = returned.fileattr

                if (cmn & attrgroup_t(ATTR_CMN_ERROR)) != 0 {
                    guard fieldPtr + 4 <= entryEnd else { continue }
                    let err = fieldPtr.loadUnaligned(as: UInt32.self)
                    fieldPtr += 4
                    if err != 0 {
                        continue
                    }
                }

                var nameCStringPtr: UnsafePointer<CChar>?
                if (cmn & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                    guard fieldPtr + attrRefSize <= entryEnd else { continue }
                    let nameFieldPtr = fieldPtr
                    let nameRef = fieldPtr.loadUnaligned(as: attrreference_t.self)
                    fieldPtr += attrRefSize
                    let nameDataPtr = nameFieldPtr + Int(nameRef.attr_dataoffset)
                    if nameDataPtr >= entryPtr && nameDataPtr < entryEnd {
                        nameCStringPtr = UnsafePointer(nameDataPtr.assumingMemoryBound(to: CChar.self))
                    }
                }

                var dev: Int32 = 0
                if (cmn & attrgroup_t(ATTR_CMN_DEVID)) != 0 {
                    guard fieldPtr + 4 <= entryEnd else { continue }
                    dev = fieldPtr.loadUnaligned(as: Int32.self)
                    fieldPtr += 4
                }

                var objType: UInt32 = 0
                if (cmn & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                    guard fieldPtr + 4 <= entryEnd else { continue }
                    objType = fieldPtr.loadUnaligned(as: UInt32.self)
                    fieldPtr += 4
                }

                var fileID: UInt64 = 0
                if (cmn & attrgroup_t(ATTR_CMN_FILEID)) != 0 {
                    guard fieldPtr + 8 <= entryEnd else { continue }
                    fileID = fieldPtr.loadUnaligned(as: UInt64.self)
                    fieldPtr += 8
                }

                var linkCount: UInt32 = 2
                if (file & attrgroup_t(ATTR_FILE_LINKCOUNT)) != 0 {
                    guard fieldPtr + 4 <= entryEnd else { continue }
                    linkCount = fieldPtr.loadUnaligned(as: UInt32.self)
                    fieldPtr += 4
                }

                var hasAllocSize = false
                var allocSize: Int64 = 0
                if (file & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0 {
                    guard fieldPtr + 8 <= entryEnd else { continue }
                    allocSize = fieldPtr.loadUnaligned(as: Int64.self)
                    fieldPtr += 8
                    hasAllocSize = true
                }

                var hasDataAllocSize = false
                var dataAllocSize: Int64 = 0
                if (file & attrgroup_t(ATTR_FILE_DATAALLOCSIZE)) != 0 {
                    guard fieldPtr + 8 <= entryEnd else { continue }
                    dataAllocSize = fieldPtr.loadUnaligned(as: Int64.self)
                    fieldPtr += 8
                    hasDataAllocSize = true
                }

                if objType == UInt32(VREG.rawValue) {
                    if linkCount > 1 && fileID != 0 {
                        let key = InodeKey(dev: dev, ino: fileID)
                        if !seenInodes.insert(key).inserted {
                            continue
                        }
                    }
                    if hasAllocSize {
                        fileBytes += max(0, allocSize)
                    } else if hasDataAllocSize {
                        fileBytes += max(0, dataAllocSize)
                    }
                } else if objType == UInt32(VDIR.rawValue) {
                    guard let nameCStringPtr else { continue }
                    let name = String(cString: nameCStringPtr)
                    if name == "." || name == ".." || name.isEmpty {
                        continue
                    }
                    subdirs.append(prefixPath + name)
                }
            }
        }

        return (fileBytes, subdirs, false)
    }
}
