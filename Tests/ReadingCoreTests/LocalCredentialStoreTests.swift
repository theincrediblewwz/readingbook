import Foundation
import Darwin
import XCTest
@testable import ReadingCore

final class LocalCredentialStoreTests: XCTestCase {
    private struct Fixture {
        let temporary: URL
        let directory: URL
        let store: LocalCredentialStore
        var file: URL { directory.appendingPathComponent("credentials.json") }
    }
    private func fixture() throws -> Fixture {
        // Foundation's resolving/standardized URL APIs strip /private on macOS,
        // so they can reintroduce the system /var symlink. Only the trusted test
        // base is resolved here; the store must still reject arbitrary links.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(physical) }
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("ReadingBook-Credentials-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let directory = temporary.appendingPathComponent("ReadingBook-Private", isDirectory: true)
        return Fixture(temporary: temporary, directory: directory, store: LocalCredentialStore(directoryURL: directory))
    }
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    func testRoundTripReloadPermissionsAndRemovalKeepOtherServices() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        XCTAssertNil(try f.store.key(for: "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path), "A missing key lookup need not create files.")
        try f.store.save("fixture-a", for: "a")
        try f.store.save("fixture-b", for: "b")
        XCTAssertEqual(try mode(f.directory), 0o700)
        XCTAssertEqual(try mode(f.file), 0o600)
        let reload = LocalCredentialStore(directoryURL: f.directory)
        XCTAssertEqual(try reload.key(for: "a"), "fixture-a")
        XCTAssertEqual(try reload.key(for: "b"), "fixture-b")
        try reload.remove(for: "a")
        XCTAssertNil(try reload.key(for: "a"))
        XCTAssertEqual(try reload.key(for: "b"), "fixture-b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["credentials.json"])
    }

    func testExplicitRecoveryNeverOverwritesLocalValuesIncludingEmptyKeys() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        XCTAssertEqual(try f.store.saveIfAbsent("old-fixture", for: "legacy"), "old-fixture")
        try f.store.save("new-fixture", for: "legacy")
        XCTAssertEqual(try f.store.saveIfAbsent("old-fixture", for: "legacy"), "new-fixture")
        try f.store.save("", for: "local-server")
        XCTAssertEqual(try f.store.saveIfAbsent("must-not-return", for: "local-server"), "")
        XCTAssertEqual(try f.store.key(for: "local-server"), "")
        try f.store.remove(for: "missing")
        XCTAssertEqual(try f.store.key(for: "legacy"), "new-fixture")
    }

    func testPhysicalPathIsPreservedWhileUntrustedURLsAndAliasAncestorsAreRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        try f.store.save("fixture", for: "a")
        XCTAssertEqual(try f.store.key(for: "a"), "fixture", "A physical path must not be rewritten through a Foundation system alias.")
        let original = try Data(contentsOf: f.file)
        for (label, url) in [
            ("remote-host", try XCTUnwrap(URL(string: "file://credentials.invalid" + f.directory.path))),
            ("dotdot", f.temporary.appendingPathComponent("../" + f.temporary.lastPathComponent + "/ReadingBook-Private", isDirectory: true)),
            ("encoded-dotdot", try XCTUnwrap(URL(string: f.temporary.absoluteString + "%2e%2e/" + f.temporary.lastPathComponent + "/ReadingBook-Private/"))),
            ("encoded-NUL", try XCTUnwrap(URL(string: f.temporary.absoluteString + "bad%00path/")))
        ] {
            let untrusted = LocalCredentialStore(directoryURL: url)
            XCTAssertThrowsError(try untrusted.key(for: "a"), label)
            XCTAssertThrowsError(try untrusted.save("must-not-write", for: "a"), label)
        }
        let literalPercent = LocalCredentialStore(directoryURL: f.temporary.appendingPathComponent("literal-%00", isDirectory: true))
        try literalPercent.save("literal-fixture", for: "a")
        XCTAssertEqual(try literalPercent.key(for: "a"), "literal-fixture", "A literal percent filename is not an encoded NUL; do not decode twice.")
        let alias = f.temporary.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.temporary)
        let aliased = LocalCredentialStore(directoryURL: alias.appendingPathComponent("ReadingBook-Private", isDirectory: true))
        XCTAssertThrowsError(try aliased.key(for: "a"))
        XCTAssertThrowsError(try aliased.save("must-not-write", for: "a"))
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }

    func testDirectoryAndFileSymlinksCannotRedirectSecrets() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        let external = f.temporary.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: external)
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("fixture", for: "a"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        try FileManager.default.removeItem(at: f.directory)
        try f.store.save("safe-fixture", for: "a")
        let externalFile = external.appendingPathComponent("keep.json"), original = try Data(contentsOf: f.file)
        try original.write(to: externalFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: externalFile.path)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: externalFile)
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("must-not-write", for: "a"))
        XCTAssertThrowsError(try f.store.remove(for: "a"))
        XCTAssertEqual(try Data(contentsOf: externalFile), original)
    }

    func testHardLinksUnsafeFilePermissionsAndCorruptDataArePreserved() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        try f.store.save("fixture", for: "a")
        let original = try Data(contentsOf: f.file), linked = f.temporary.appendingPathComponent("linked.json")
        try FileManager.default.linkItem(at: f.file, to: linked)
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("must-not-write", for: "a"))
        XCTAssertEqual(try Data(contentsOf: linked), original)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.file.path)
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("must-not-write", for: "a"))
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.file.path)
        let corrupt = Data("incomplete-fixture".utf8)
        try corrupt.write(to: f.file)
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("must-not-write", for: "a"))
        XCTAssertEqual(try Data(contentsOf: f.file), corrupt)
    }

    func testUntrustedAncestorAndOversizedInputCannotReplaceExistingValues() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        try f.store.save("fixture", for: "a")
        let original = try Data(contentsOf: f.file)
        XCTAssertThrowsError(try f.store.save(String(repeating: "x", count: 65_537), for: "a"))
        XCTAssertThrowsError(try f.store.save("fixture", for: ""))
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: f.temporary.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.temporary.path) }
        XCTAssertThrowsError(try f.store.key(for: "a"))
        XCTAssertThrowsError(try f.store.save("must-not-write", for: "a"))
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }

    func testConcurrentInstancesKeepEverySavedService() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.temporary) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let store = LocalCredentialStore(directoryURL: f.directory)
                    try store.save("fixture-\(index)", for: "service-\(index)")
                }
            }
            try await group.waitForAll()
        }
        for index in 0..<24 { XCTAssertEqual(try f.store.key(for: "service-\(index)"), "fixture-\(index)") }
        XCTAssertEqual(try mode(f.directory), 0o700)
        XCTAssertEqual(try mode(f.file), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path), ["credentials.json"])
    }
}
