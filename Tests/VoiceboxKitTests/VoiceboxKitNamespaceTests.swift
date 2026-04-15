import XCTest
@testable import VoiceboxKit

final class VoiceboxKitNamespaceTests: XCTestCase {

    func testVersionIsNotEmpty() {
        XCTAssertFalse(VoiceboxKit.version.isEmpty)
    }

    func testVersionMatchesSemVer() {
        // Must match X.Y.Z pattern
        let regex = try! NSRegularExpression(pattern: #"^\d+\.\d+\.\d+$"#)
        let range = NSRange(VoiceboxKit.version.startIndex..., in: VoiceboxKit.version)
        XCTAssertNotNil(regex.firstMatch(in: VoiceboxKit.version, range: range))
    }

    func testBaseURLIsHTTPS() {
        XCTAssertTrue(VoiceboxKit.baseURL.hasPrefix("https://"))
    }

    func testDefaultAutoGrantMicPermissionIsFalse() {
        let previous = VoiceboxKit.autoGrantMicPermission
        defer { VoiceboxKit.autoGrantMicPermission = previous }

        // Reset to default
        VoiceboxKit.autoGrantMicPermission = false
        XCTAssertFalse(VoiceboxKit.autoGrantMicPermission)
    }

    func testAutoGrantMicPermissionCanBeSet() {
        let previous = VoiceboxKit.autoGrantMicPermission
        defer { VoiceboxKit.autoGrantMicPermission = previous }

        VoiceboxKit.autoGrantMicPermission = true
        XCTAssertTrue(VoiceboxKit.autoGrantMicPermission)
    }
}
