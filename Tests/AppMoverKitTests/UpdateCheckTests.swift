import Testing
import Foundation
@testable import AppMoverKit

@Suite("Update check")
struct UpdateCheckTests {
    @Test("a later release is newer, whatever the tag prefix or part count", arguments: [
        ("v0.2.0", "0.1.0", true),
        ("v0.10.0", "0.9.0", true),  // numeric, not alphabetical
        ("1.0.1", "1.0", true),
        ("v0.1.0", "0.1.0", false),
        ("v1.0", "1.0.0", false),    // a missing part counts as 0
        ("v0.1.0", "0.2.0", false),
    ])
    func comparesVersions(tag: String, current: String, isNewer: Bool) {
        #expect(UpdateCheck.isNewer(tag, than: current) == isNewer)
    }

    @Test("reads the tag from GitHub's latest-release response")
    func readsTag() throws {
        let body = Data(#"{"tag_name": "v0.3.0", "name": "AppMover 0.3.0"}"#.utf8)
        #expect(try UpdateCheck.tag(from: body, status: 200) == "v0.3.0")
    }

    @Test("a tag that isn't a version number is rejected, not shown in the banner")
    func rejectsNonVersionTag() {
        let body = Data(#"{"tag_name": "nightly <b>now</b>"}"#.utf8)
        #expect(throws: URLError.self) { try UpdateCheck.tag(from: body, status: 200) }
    }

    @Test("no published release is not an update and not an error")
    func noReleaseYet() throws {
        #expect(try UpdateCheck.tag(from: Data(#"{"message": "Not Found"}"#.utf8), status: 404) == nil)
    }

    @Test("a rate limit or server error throws rather than passing for up to date")
    func serverError() {
        #expect(throws: URLError.self) {
            try UpdateCheck.tag(from: Data(#"{"message": "API rate limit exceeded"}"#.utf8), status: 403)
        }
    }
}
