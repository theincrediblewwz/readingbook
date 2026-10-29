#if os(macOS)
import Foundation
import XCTest
@testable import ReadingCore

final class PDFDisplaySourceVersionTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let url: URL
        let bytes: Data
        let hash: String
    }

    private func fixture(_ bytes: Data = Data("Display source version fixture.\n".utf8)) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-display-version-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.pdf")
        try bytes.write(to: url)
        return Fixture(directory: directory, url: url, bytes: bytes, hash: try BookImporter.sha256(bytes))
    }

    private func requireVerificationFailure(_ url: URL, hash: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await PDFDisplaySourceVersion.verify(at: url, expectedSourceHash: hash)
            XCTFail("An unverified source must not produce a display receipt.", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ReadingError, "Source admission failures use the existing ReadingError domain.", file: file, line: line)
        }
    }

    func testUnchangedSourceReturnsStableValueWithoutParsingOrWritingPDF() async throws {
        // Deliberately not PDF syntax: byte admission is independent of PDFKit parsing.
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let version = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        let again = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        XCTAssertEqual(version.canonicalPath, source.url.standardizedFileURL.path)
        XCTAssertEqual(version.actualSourceHash, source.hash)
        XCTAssertEqual(version, again)
        XCTAssertTrue(try version.matchesCurrentFileMetadata())
        XCTAssertEqual(try Data(contentsOf: source.url), source.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.directory.path), ["source.pdf"])
    }

    func testSameSizeInPlaceMutationCannotReuseOldReceiptEvenWhenMtimeIsRestored() async throws {
        let source = try fixture(Data(repeating: 65, count: 4096))
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
        let before = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        let changed = Data(repeating: 66, count: source.bytes.count)
        let handle = try FileHandle(forWritingTo: source.url)
        try handle.write(contentsOf: changed); try handle.close()
        if let modified = attributes[.modificationDate] {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.url.path)
        }
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, afterAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(attributes[.size] as? NSNumber, afterAttributes[.size] as? NSNumber)
        XCTAssertFalse(try before.matchesCurrentFileMetadata())
        await requireVerificationFailure(source.url, hash: source.hash)
        let after = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: try BookImporter.sha256(changed))
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(try after.matchesCurrentFileMetadata())
    }

    func testAtomicReplacementWithIdenticalBytesHasANewFileIdentity() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let inode = try FileManager.default.attributesOfItem(atPath: source.url.path)[.systemFileNumber] as? NSNumber
        let before = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        try source.bytes.write(to: source.url, options: .atomic)
        let nextInode = try FileManager.default.attributesOfItem(atPath: source.url.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(inode, nextInode)
        XCTAssertFalse(try before.matchesCurrentFileMetadata())
        let after = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        XCTAssertEqual(after.actualSourceHash, before.actualSourceHash)
        XCTAssertNotEqual(before, after)
    }

    func testMetadataOnlyChangeInvalidatesPriorReceipt() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let before = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123_456)], ofItemAtPath: source.url.path)
        XCTAssertFalse(try before.matchesCurrentFileMetadata())
        let after = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        XCTAssertEqual(after.actualSourceHash, before.actualSourceHash)
        XCTAssertNotEqual(before, after)
    }

    func testDeletedSourceNeverMatchesOrVerifies() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let before = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        try FileManager.default.removeItem(at: source.url)
        XCTAssertThrowsError(try before.matchesCurrentFileMetadata())
        await requireVerificationFailure(source.url, hash: source.hash)
    }

    func testSymlinkCannotBeAdmittedOrReplaceAnExistingReceipt() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let before = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        let target = source.directory.appendingPathComponent("target.pdf")
        try source.bytes.write(to: target)
        try FileManager.default.removeItem(at: source.url)
        try FileManager.default.createSymbolicLink(at: source.url, withDestinationURL: target)
        XCTAssertThrowsError(try before.matchesCurrentFileMetadata())
        await requireVerificationFailure(source.url, hash: source.hash)
        XCTAssertEqual(try Data(contentsOf: target), source.bytes)
    }

    func testWrongOrMalformedExpectedHashDoesNotAuthorizeBytes() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.directory) }
        for wrong in ["", "not-a-hash", String(repeating: "f", count: 64), source.hash.uppercased(), String(repeating: "é", count: 32)] {
            await requireVerificationFailure(source.url, hash: wrong)
        }
        XCTAssertEqual(try Data(contentsOf: source.url), source.bytes)
    }

    func testEmptyDirectoryNonFileAndOversizedSourcesAreRejectedBeforeHashing() async throws {
        let source = try fixture(Data())
        defer { try? FileManager.default.removeItem(at: source.directory) }
        await requireVerificationFailure(source.url, hash: source.hash)
        await requireVerificationFailure(source.directory, hash: source.hash)
        await requireVerificationFailure(try XCTUnwrap(URL(string: "https://example.invalid/source.pdf")), hash: source.hash)
        let handle = try FileHandle(forWritingTo: source.url)
        try handle.truncate(atOffset: 256 * 1_024 * 1_024 + 1); try handle.close()
        await requireVerificationFailure(source.url, hash: source.hash)
    }

    func testCancellationDoesNotReturnADisplayReceipt() async throws {
        let source = try fixture(Data(repeating: 82, count: 8 * 1_024 * 1_024))
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        }
        do { _ = try await cancelled.value; XCTFail("An already cancelled verification returned a receipt.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let running = Task { try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash) }
        running.cancel()
        do { _ = try await running.value; XCTFail("A cancelled verification returned a receipt.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let valid = try await PDFDisplaySourceVersion.verify(at: source.url, expectedSourceHash: source.hash)
        XCTAssertTrue(try valid.matchesCurrentFileMetadata())
    }
}
#endif
