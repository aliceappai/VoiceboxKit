import XCTest
@testable import VoiceboxKit

final class CacheTests: XCTestCase {

    func testCacheDefaultsToEmpty() {
        let cache = VoiceboxCache.shared
        // A random handle should not have cached content
        let randomHandle = "test-\(UUID().uuidString)"
        XCTAssertFalse(cache.hasCachedContent(for: randomHandle))
    }
}
