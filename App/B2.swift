import Foundation

// A minimal client for Backblaze B2's native API (v3): just enough to list every version of the
// files under a prefix and to delete single versions by id. rclone can't do either with an age
// filter, so the hidden-file cleanup talks to B2 directly, with the same key rclone uses.

struct B2Error: LocalizedError {
    var status: Int
    var code: String
    var message: String
    var errorDescription: String? { message.isEmpty ? "B2 error \(status) (\(code))" : "B2: \(message)" }
}

/// One stored version of a file, as `b2_list_file_versions` returns it.
struct B2Version: Hashable {
    var id: String
    var name: String
    /// "upload", "hide", "start" (unfinished large file) or "folder".
    var action: String
    var size: Int64
    var uploaded: Date
}

final class B2Client: @unchecked Sendable {
    struct Credentials {
        var keyID: String
        var appKey: String
        /// Authorization endpoint; rclone's `endpoint` option when set.
        var endpoint = "https://api.backblazeb2.com"
    }

    private struct Session {
        var token: String
        var apiURL: String
        var accountID: String
        var bucketID: String?
        var bucketName: String?
        var capabilities: [String]
    }

    private let credentials: Credentials
    private let urlSession: URLSession
    private let lock = NSLock()
    private var session: Session?
    /// Exposed for tests: how long to wait before retrying a busy server.
    var retryDelay: (Int) -> Double = { attempt in pow(2, Double(attempt)) }

    init(_ credentials: Credentials, configuration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Bucketwatch"]
        urlSession = URLSession(configuration: configuration)
    }

    deinit { urlSession.finishTasksAndInvalidate() }

    // MARK: Session

    private func authorize() async throws -> Session {
        guard let url = URL(string: credentials.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                            + "/b2api/v3/b2_authorize_account") else {
            throw B2Error(status: 0, code: "bad_endpoint", message: "Invalid B2 endpoint")
        }
        var request = URLRequest(url: url)
        let basic = Data("\(credentials.keyID):\(credentials.appKey)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let obj = try await send(request)
        // v3 nests the storage details under apiInfo.storageApi; older answers had them at the top.
        let storage = (obj["apiInfo"] as? [String: Any])?["storageApi"] as? [String: Any] ?? obj
        let allowed = storage["allowed"] as? [String: Any] ?? storage
        guard let token = obj["authorizationToken"] as? String,
              let apiURL = storage["apiUrl"] as? String,
              let accountID = obj["accountId"] as? String else {
            throw B2Error(status: 0, code: "bad_response", message: "Unexpected answer from b2_authorize_account")
        }
        let s = Session(token: token, apiURL: apiURL, accountID: accountID,
                        bucketID: allowed["bucketId"] as? String, bucketName: allowed["bucketName"] as? String,
                        capabilities: allowed["capabilities"] as? [String] ?? [])
        lock.withLock { session = s }
        return s
    }

    private func currentSession() async throws -> Session {
        if let s = lock.withLock({ session }) { return s }
        return try await authorize()
    }

    /// The key's capabilities, e.g. "listFiles", "deleteFiles".
    func capabilities() async throws -> [String] { try await currentSession().capabilities }

    // MARK: Calls

    /// POSTs to a B2 API function. Re-authorizes once on an expired token and retries busy servers.
    private func call(_ function: String, _ body: [String: Any]) async throws -> [String: Any] {
        var reauthorized = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let s = try await currentSession()
            guard let url = URL(string: s.apiURL + "/b2api/v3/" + function) else {
                throw B2Error(status: 0, code: "bad_response", message: "Invalid B2 API URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(s.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                return try await send(request)
            } catch let error as B2Error where error.status == 401 && !reauthorized
                        && (error.code == "expired_auth_token" || error.code == "bad_auth_token") {
                reauthorized = true
                lock.withLock { session = nil }
            } catch let error as B2Error where [408, 429, 500, 503].contains(error.status) && attempt < 4 {
                attempt += 1
                try await Task.sleep(for: .seconds(retryDelay(attempt)))
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let obj else {
            throw B2Error(status: status, code: obj?["code"] as? String ?? "http_\(status)",
                          message: obj?["message"] as? String ?? "")
        }
        return obj
    }

    // MARK: Functions

    func bucketID(named name: String) async throws -> String {
        let s = try await currentSession()
        if let id = s.bucketID, s.bucketName == name { return id }
        let obj = try await call("b2_list_buckets", ["accountId": s.accountID, "bucketName": name])
        guard let bucket = (obj["buckets"] as? [[String: Any]])?.first(where: { $0["bucketName"] as? String == name }),
              let id = bucket["bucketId"] as? String else {
            throw B2Error(status: 404, code: "no_such_bucket", message: "Bucket “\(name)” not found, or the key can't see it")
        }
        return id
    }

    struct Page {
        var versions: [B2Version]
        var nextName: String?
        var nextID: String?
    }

    /// One page of versions, ordered by name and, within a name, newest first.
    func listVersions(bucketID: String, prefix: String, startName: String? = nil, startID: String? = nil,
                      max: Int = 1000) async throws -> Page {
        var body: [String: Any] = ["bucketId": bucketID, "prefix": prefix, "maxFileCount": max]
        if let startName { body["startFileName"] = startName }
        if let startID { body["startFileId"] = startID }
        let obj = try await call("b2_list_file_versions", body)
        guard let files = obj["files"] as? [[String: Any]] else {
            throw B2Error(status: 0, code: "bad_response", message: "Unexpected answer from b2_list_file_versions")
        }
        let versions = try files.map { file -> B2Version in
            guard let id = file["fileId"] as? String, let name = file["fileName"] as? String,
                  let action = file["action"] as? String,
                  let millis = (file["uploadTimestamp"] as? NSNumber)?.int64Value else {
                throw B2Error(status: 0, code: "bad_response", message: "A file version without id, name or date")
            }
            return B2Version(id: id, name: name, action: action,
                             size: (file["contentLength"] as? NSNumber)?.int64Value ?? 0,
                             uploaded: Date(timeIntervalSince1970: Double(millis) / 1000))
        }
        return Page(versions: versions, nextName: obj["nextFileName"] as? String, nextID: obj["nextFileId"] as? String)
    }

    /// Every version under `prefix`, following pagination.
    func allVersions(bucketID: String, prefix: String, pageSize: Int = 1000) async throws -> [B2Version] {
        var all: [B2Version] = []
        var startName: String?, startID: String?
        repeat {
            let page = try await listVersions(bucketID: bucketID, prefix: prefix, startName: startName,
                                              startID: startID, max: pageSize)
            all += page.versions
            startName = page.nextName
            startID = page.nextID
        } while startName != nil
        return all
    }

    /// Every version of exactly this file name. nil when there are too many to list in one call.
    func versions(of name: String, bucketID: String) async throws -> [B2Version]? {
        let max = 1000
        let page = try await listVersions(bucketID: bucketID, prefix: name, startName: name, max: max)
        let exact = page.versions.filter { $0.name == name }
        if page.versions.count == max && page.versions.last?.name == name { return nil }
        return exact
    }

    /// Deletes one version for good. A version that is already gone counts as deleted.
    func deleteVersion(name: String, id: String) async throws {
        do {
            _ = try await call("b2_delete_file_version", ["fileName": name, "fileId": id])
        } catch let error as B2Error where error.code == "file_not_present" || error.status == 404 {
            return
        }
    }
}
