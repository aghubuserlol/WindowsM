import Foundation

// Models for the UUP dump JSON API (https://api.uupdump.net).
// The API has a few historical quirks (dicts where arrays are expected,
// numbers encoded as strings), so decoding below is deliberately tolerant.

/// One Windows build offered by UUP dump (from listid.php).
struct UUPBuild: Identifiable, Hashable, Decodable {
    let uuid: String
    let title: String
    let build: String
    let arch: String
    /// Unix timestamp the build was published; used to pick the newest.
    let created: Int

    var id: String { uuid }

    private enum CodingKeys: String, CodingKey { case uuid, title, build, arch, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        title = try c.decode(String.self, forKey: .title)
        build = try c.decode(String.self, forKey: .build)
        arch = try c.decode(String.self, forKey: .arch)
        // `created` is sometimes a string; tolerate both, default to 0.
        if let i = try? c.decode(Int.self, forKey: .created) {
            created = i
        } else if let s = try? c.decode(String.self, forKey: .created), let i = Int(s) {
            created = i
        } else {
            created = 0
        }
    }
}

/// Envelope for listid.php.
struct UUPListResponse: Decodable {
    let builds: [UUPBuild]

    private enum CodingKeys: String, CodingKey { case response }
    private enum ResponseKeys: String, CodingKey { case builds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let response = try container.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response)
        if let array = try? response.decode([UUPBuild].self, forKey: .builds) {
            builds = array
        } else {
            // Older API revisions key builds by an opaque index.
            let dict = try response.decode([String: UUPBuild].self, forKey: .builds)
            builds = Array(dict.values)
        }
    }
}

/// One downloadable update package (from get.php).
struct UUPFileEntry: Identifiable, Hashable {
    let name: String
    let sha1: String
    let sizeBytes: Int64
    let url: URL

    var id: String { name }
}

/// Envelope for get.php.
struct UUPGetResponse: Decodable {
    let updateName: String?
    let files: [UUPFileEntry]

    private enum CodingKeys: String, CodingKey { case response }
    private enum ResponseKeys: String, CodingKey { case updateName, files }

    private struct FilePayload: Decodable {
        let sha1: String?
        let size: FlexibleInt64?
        let url: String?
    }

    /// The API sometimes serializes sizes as strings.
    private struct FlexibleInt64: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let int = try? single.decode(Int64.self) {
                value = int
            } else if let string = try? single.decode(String.self), let int = Int64(string) {
                value = int
            } else {
                value = 0
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let response = try container.nestedContainer(keyedBy: ResponseKeys.self, forKey: .response)
        updateName = try? response.decode(String.self, forKey: .updateName)
        let rawFiles = try response.decode([String: FilePayload].self, forKey: .files)
        files = rawFiles.compactMap { name, payload in
            guard let urlString = payload.url, let url = URL(string: urlString) else { return nil }
            return UUPFileEntry(name: name,
                                sha1: payload.sha1 ?? "",
                                sizeBytes: payload.size?.value ?? 0,
                                url: url)
        }
        .sorted { $0.name < $1.name }
    }
}
