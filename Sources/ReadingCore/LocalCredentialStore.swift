import Foundation
import Darwin

/// Machine-local provider secrets. This directory is deliberately a sibling of
/// the default library, never a member of its backup/export tree.
public struct LocalCredentialStore: Sendable {
    public static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ReadingBook-Private", isDirectory: true)
    }
    public let directoryURL: URL
    private static let lock = NSLock()
    private static let fileName = "credentials.json"
    private static let byteLimit = 2 * 1_024 * 1_024
    private struct Contents: Codable {
        var version = 1
        var keys: [String: String] = [:]
    }

    public init(directoryURL: URL = LocalCredentialStore.defaultDirectoryURL) { self.directoryURL = directoryURL }

    /// nil means absent; an intentionally saved empty key remains an entry.
    public func key(for serviceID: String) throws -> String? {
        try synchronized {
            try validate(serviceID: serviceID)
            guard let directory = try openDirectory(create: false) else { return nil }
            defer { close(directory) }
            return try read(directory).keys[serviceID]
        }
    }

    public func save(_ key: String, for serviceID: String) throws {
        try update(serviceID: serviceID) { values in values[serviceID] = key }
    }

    /// The old Keychain can only fill a missing local slot, never replace a key
    /// entered or saved while the explicit recovery dialog was open.
    @discardableResult public func saveIfAbsent(_ key: String, for serviceID: String) throws -> String {
        try update(serviceID: serviceID) { values in
            if values[serviceID] == nil { values[serviceID] = key }
            return values[serviceID] ?? key
        }
    }

    public func remove(for serviceID: String) throws {
        try synchronized {
            try validate(serviceID: serviceID)
            guard let directory = try openDirectory(create: false) else { return }
            defer { close(directory) }
            try lockDirectory(directory)
            defer { _ = flock(directory, LOCK_UN) }
            var contents = try read(directory)
            guard contents.keys.removeValue(forKey: serviceID) != nil else { return }
            try write(contents, in: directory)
        }
    }

    private func update<T>(serviceID: String, change: (inout [String: String]) throws -> T) throws -> T {
        try synchronized {
            try validate(serviceID: serviceID)
            guard let directory = try openDirectory(create: true) else { throw failure() }
            defer { close(directory) }
            try lockDirectory(directory)
            defer { _ = flock(directory, LOCK_UN) }
            var contents = try read(directory)
            let result = try change(&contents.keys)
            try validate(contents)
            try write(contents, in: directory)
            return result
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try operation()
    }

    private func lockDirectory(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw failure()
        }
    }

    private func validate(serviceID: String) throws {
        guard !serviceID.isEmpty, serviceID.utf8.count <= 256,
              !serviceID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw failure() }
    }

    private func validate(_ contents: Contents) throws {
        guard contents.version == 1, contents.keys.count <= 256 else { throw failure() }
        for (id, key) in contents.keys {
            try validate(serviceID: id)
            guard key.utf8.count <= 65_536 else { throw failure() }
        }
    }

    /// Traverse with directory descriptors rather than resolving a user-created
    /// symlink. Only the final private directory may be created or chmodded.
    private func openDirectory(create: Bool) throws -> Int32? {
        let path = directoryURL.path
        guard let declared = URLComponents(string: directoryURL.absoluteString) else { throw failure() }
        let encodedPath = declared.percentEncodedPath
        // URL.path can sanitize an encoded NUL instead of exposing a zero byte.
        // Inspect the original escaped path too, without decoding literal %25
        // twice or letting URL standardization hide dot components.
        let declaredComponents = encodedPath.replacingOccurrences(of: "%2e", with: ".", options: .caseInsensitive)
            .split(separator: "/").map(String.init)
        // Foundation standardization may turn a physical /private/var path back
        // into the /var symlink on macOS. Validate lexically, then let each
        // O_NOFOLLOW open prove the actual directory instead of rewriting it.
        guard directoryURL.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0), !encodedPath.contains("%00"),
              !declaredComponents.contains("."), !declaredComponents.contains(".."),
              directoryURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true,
              directoryURL.user == nil, directoryURL.password == nil, directoryURL.port == nil,
              directoryURL.query == nil, directoryURL.fragment == nil else { throw failure() }
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2, !components.contains("."), !components.contains("..") else { throw failure() }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure() }
        defer { if current >= 0 { close(current) } }
        for (index, component) in components.enumerated() {
            let final = index == components.count - 1
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if !create { return nil }
                guard final, mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw failure() }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw failure() }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                close(next); throw failure()
            }
            if final {
                guard info.st_uid == geteuid(), fchmod(next, mode_t(0o700)) == 0 else { close(next); throw failure() }
            } else {
                let trustedTemporary = info.st_uid == 0 && info.st_mode & mode_t(S_ISVTX) != 0
                guard (info.st_uid == 0 || info.st_uid == geteuid()),
                      info.st_mode & mode_t(0o022) == 0 || trustedTemporary else { close(next); throw failure() }
            }
            close(current); current = next
        }
        let result = current; current = -1
        return result
    }

    private func read(_ directory: Int32) throws -> Contents {
        let descriptor = openat(directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return Contents() }
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        try validateFile(info)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= Self.byteLimit - data.count else { throw failure() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == Int(info.st_size) else { throw failure() }
        let contents: Contents
        do { contents = try JSONDecoder().decode(Contents.self, from: data) }
        catch { throw failure() }
        try validate(contents)
        return contents
    }

    private func validateFile(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(0o777) == mode_t(0o600), info.st_size >= 0, info.st_size <= Int64(Self.byteLimit) else { throw failure() }
    }

    private func write(_ contents: Contents, in directory: Int32) throws {
        try validate(contents)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(contents)
        guard data.count <= Self.byteLimit else { throw failure() }
        let temporary = ".credentials-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw failure() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure() }
        // Refuse links and foreign files even though rename itself does not
        // follow the destination. The descriptor also pins the private folder.
        var destination = stat()
        let status = fstatat(directory, Self.fileName, &destination, AT_SYMLINK_NOFOLLOW)
        if status == 0 { try validateFile(destination) }
        else if errno != ENOENT { throw failure() }
        guard renameat(directory, temporary, directory, Self.fileName) == 0 else { throw failure() }
        _ = fsync(directory)
    }

    private func failure() -> ReadingError {
        ReadingError.invalid("本机密钥文件无法安全读写，请检查 App 私有目录及权限；已有密钥保留。")
    }
}
