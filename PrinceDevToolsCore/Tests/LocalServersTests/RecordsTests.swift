import XCTest
@testable import LocalServers

final class RecordsTests: XCTestCase {
    private let home = "/Users/u"
    private let identity = FileIdentity(inode: 1, device: 1)

    private func folder(_ path: String) -> FolderReading {
        .path(path, identity: identity)
    }

    func testHomeFolderItselfIsIn() {
        XCTAssertTrue(folder("/Users/u").isInHomeFolder(home))
    }

    func testFolderBelowHomeIsIn() {
        XCTAssertTrue(folder("/Users/u/src/app").isInHomeFolder(home))
    }

    func testSiblingWhoseNameStartsWithHomeIsOut() {
        XCTAssertFalse(folder("/Users/uu/app").isInHomeFolder(home))
    }

    func testRootIsOut() {
        XCTAssertFalse(folder("/").isInHomeFolder(home))
    }

    func testHomebrewIsOut() {
        XCTAssertFalse(folder("/opt/homebrew/var").isInHomeFolder(home))
    }

    func testUnreadableFolderIsIn() {
        XCTAssertTrue(FolderReading.unreadable.isInHomeFolder(home))
    }

    func testEmptyPathIsIn() {
        XCTAssertTrue(folder("").isInHomeFolder(home))
    }

    func testHomeWithTrailingSlashStillMatches() {
        XCTAssertTrue(folder("/Users/u/app").isInHomeFolder("/Users/u/"))
    }
}
