@testable import Ata
import XCTest

/// Answers each request with the next status in `statuses`, and records what was asked.
private final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let status = Self.statuses.isEmpty ? 500 : Self.statuses.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("status \(status)".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DownloaderRetryTests: XCTestCase {
    private let primary = URL(string: "https://example.test/Ata.zip")!
    private var dest: URL!

    override func setUp() {
        dest = FileManager.default.temporaryDirectory.appendingPathComponent("retry-\(UUID().uuidString).zip")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dest) }

    private func run(statuses: [Int], fallback: URLRequest? = nil, delays: Int = 3) -> (Error?, [URLRequest]) {
        ScriptedProtocol.lock.lock()
        ScriptedProtocol.statuses = statuses
        ScriptedProtocol.seen = []
        ScriptedProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedProtocol.self]
        let finished = expectation(description: "download finished")
        let box = ErrorBox()
        let d = Downloader(dest: dest, fallback: fallback, retryDelays: Array(repeating: 0.01, count: delays),
                           configuration: config, progress: { _ in }, completion: { error in
            box.error = error
            finished.fulfill()
        })
        d.start(primary)
        wait(for: [finished], timeout: 10)
        ScriptedProtocol.lock.lock()
        defer { ScriptedProtocol.lock.unlock() }
        return (box.error, ScriptedProtocol.seen)
    }

    /// The release that could not be installed on 2026-11-08: one 504 ended the update.
    func testA504IsRetriedAndTheFileArrives() {
        let (error, seen) = run(statuses: [504, 200])
        XCTAssertNil(error)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(try? String(contentsOf: dest, encoding: .utf8), "status 200")
    }

    func testRetriesAlternateWithTheFallback() {
        var api = URLRequest(url: URL(string: "https://api.example.test/assets/1")!)
        api.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (error, seen) = run(statuses: [504, 504, 200], fallback: api)
        XCTAssertNil(error)
        XCTAssertEqual(seen.map { $0.url?.host }, ["example.test", "api.example.test", "example.test"])
        XCTAssertEqual(seen[1].value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testA404IsNotRetried() {
        let (error, seen) = run(statuses: [404, 200])
        XCTAssertEqual((error as NSError?)?.code, 404)
        XCTAssertEqual(seen.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testItGivesUpOnceTheRetriesRunOut() {
        let (error, seen) = run(statuses: [503, 503, 503, 503, 200], delays: 2)
        XCTAssertEqual((error as NSError?)?.code, 503)
        XCTAssertEqual(seen.count, 3)
    }

    func testTheUpdateFeedExposesTheAPIRouteOfTheZip() throws {
        let json = """
        {"tag_name":"v3.5.2","draft":false,"prerelease":false,"body":"","assets":[
          {"name":"Ata-3.5.2.dmg","browser_download_url":"https://github.test/a.dmg","url":"https://api.github.test/assets/1"},
          {"name":"Ata-3.5.2.zip","browser_download_url":"https://github.test/a.zip","url":"https://api.github.test/assets/2"}
        ]}
        """
        let release = try JSONDecoder().decode(Updater.GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.zipAsset?.browser_download_url, "https://github.test/a.zip")
        XCTAssertEqual(release.zipAsset?.apiRequest?.url?.absoluteString, "https://api.github.test/assets/2")
        XCTAssertEqual(release.zipAsset?.apiRequest?.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}
