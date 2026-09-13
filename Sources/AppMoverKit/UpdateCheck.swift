import Foundation

/// Asks GitHub whether a release newer than this build has been published.
///
/// ponytail: notify, don't install -- the user downloads the release themselves. Swap in
/// Sparkle once a Developer ID makes silent installs worth an EdDSA key and an appcast.
public enum UpdateCheck {
    /// Opened for the user instead of the release URL in the response: a fixed address needs
    /// no trust in what the API sent back.
    public static let releasesPage = URL(string: "https://github.com/gaurav-singh-mrg/AppMover/releases/latest")!
    static let latestRelease = URL(string: "https://api.github.com/repos/gaurav-singh-mrg/AppMover/releases/latest")!

    /// The newer release's version, e.g. "0.3.0", or nil when this build is current.
    public static func newerVersion(than current: String) async throws -> String? {
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let tag = try tag(from: data, status: status), isNewer(tag, than: current) else {
            return nil
        }
        return String(tag.trimmingPrefix("v"))
    }

    static func tag(from data: Data, status: Int) throws -> String? {
        switch status {
        case 200:
            let tag = try JSONDecoder().decode(Release.self, from: data).tagName
            // It ends up in the banner, so only a plain version number gets through.
            guard tag.wholeMatch(of: /v?[0-9]+(\.[0-9]+)*/) != nil else {
                throw URLError(.cannotParseResponse)
            }
            return tag
        // Nothing published yet. Drafts and pre-releases also stay invisible to this endpoint.
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }

    /// Compared part by part as numbers, so 0.10.0 is newer than 0.9.0 and 1.0 equals 1.0.0.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let (new, old) = (numbers(tag), numbers(current))
        let width = max(new.count, old.count)
        let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: width - parts.count) }
        return padded(old).lexicographicallyPrecedes(padded(new))
    }

    /// "v1.2.0" -> [1, 2, 0]. A part that isn't a number counts as 0.
    private static func numbers(_ version: String) -> [Int] {
        version.trimmingPrefix("v").split(separator: ".").map { Int($0) ?? 0 }
    }

    private struct Release: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }
}
