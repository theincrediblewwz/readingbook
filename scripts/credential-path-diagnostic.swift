import Foundation
import Darwin

func inspect(_ label: String, path: String) {
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    let openError = errno
    print("credential-path \(label) root fdOK=\(descriptor >= 0) errno=\(descriptor >= 0 ? 0 : openError)")
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    let components = path.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
        var info = stat()
        let status = fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW)
        let statError = errno
        let kind = status == 0 ? info.st_mode & mode_t(S_IFMT) : 0
        let publicName = ["private", "var", "folders", "T", "tmp"].contains(component) ? component : "redacted"
        let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        let openError = errno
        print("credential-path \(label) index=\(index) name=\(publicName) statOK=\(status == 0) statErrno=\(status == 0 ? 0 : statError) kind=\(String(kind, radix: 8)) permissions=\(String(info.st_mode & 0o7777, radix: 8)) owner=\(info.st_uid == geteuid() ? "self" : info.st_uid == 0 ? "root" : "other") fdOK=\(next >= 0) openErrno=\(next >= 0 ? 0 : openError)")
        guard next >= 0 else { return }
        close(descriptor); descriptor = next
    }
    let locking = flock(descriptor, LOCK_EX | LOCK_NB)
    let lockingError = errno
    print("credential-path \(label) directoryFlockOK=\(locking == 0) errno=\(locking == 0 ? 0 : lockingError)")
    if locking == 0 { _ = flock(descriptor, LOCK_UN) }
}

let base = FileManager.default.temporaryDirectory
let resolvedBase = base.resolvingSymlinksInPath()
let fixture = resolvedBase.appendingPathComponent("ReadingBook-Credential-Diagnostic-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: fixture) }
inspect("foundation-resolved-before-create", path: fixture.path)
inspect("foundation-resolved-after-create", path: fixture.resolvingSymlinksInPath().path)
if let canonical = realpath(fixture.path, nil) {
    defer { free(canonical) }
    let path = String(cString: canonical)
    inspect("posix-realpath", path: path)
    print("credential-path realpathEqualsFoundation=\(path == fixture.path) fileURLRetainsRealpath=\(URL(fileURLWithPath: path, isDirectory: true).path == path) standardizedRetainsRealpath=\(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path)")
} else { print("credential-path realpath failed errno=\(errno)") }
print("credential-path flags O_DIRECTORY=\(O_DIRECTORY) O_NOFOLLOW=\(O_NOFOLLOW) O_CLOEXEC=\(O_CLOEXEC)")
