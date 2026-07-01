import XCTest
@testable import HermesAgent

final class HermesAgentLogicTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func testCronJobDecodesWithoutLastError() throws {
        let json = """
        {
          "id": "abc123def456",
          "name": "Morning brief",
          "schedule": "0 9 * * *",
          "deliver": "local",
          "status": "active",
          "nextRun": "2026-07-02 09:00",
          "script": "",
          "lastRun": ""
        }
        """.data(using: .utf8)!
        let job = try decoder.decode(CronJob.self, from: json)
        XCTAssertEqual(job.id, "abc123def456")
        XCTAssertNil(job.lastError)
        XCTAssertTrue(job.isActive)
    }

    func testCronJobDecodesWithLastError() throws {
        let json = """
        {
          "id": "abc123def456",
          "name": "LINE digest",
          "schedule": "0 8 * * *",
          "deliver": "line:Uabc",
          "status": "active",
          "nextRun": "2026-07-02 08:00",
          "script": "",
          "lastRun": "2026-07-01 08:00",
          "lastError": "Delivery failed: LINE push 401"
        }
        """.data(using: .utf8)!
        let job = try decoder.decode(CronJob.self, from: json)
        XCTAssertEqual(job.lastError, "Delivery failed: LINE push 401")
    }

    func testCronJobsResponseDecodes() throws {
        let json = """
        {
          "jobs": [
            {
              "id": "job1",
              "name": "Test",
              "schedule": "*/30 * * * *",
              "deliver": "local",
              "status": "paused",
              "nextRun": "",
              "script": "",
              "lastRun": "",
              "lastError": "timeout"
            }
          ]
        }
        """.data(using: .utf8)!
        struct Resp: Codable { let jobs: [CronJob] }
        let resp = try decoder.decode(Resp.self, from: json)
        XCTAssertEqual(resp.jobs.count, 1)
        XCTAssertEqual(resp.jobs[0].lastError, "timeout")
        XCTAssertFalse(resp.jobs[0].isActive)
    }

    func testLifelogSummaryResponseDecodes() throws {
        let json = """
        { "summary": "今日は会議が多かった", "summaryAt": 1719792000.0 }
        """.data(using: .utf8)!
        let resp = try decoder.decode(APIClient.LifelogSummaryResponse.self, from: json)
        XCTAssertEqual(resp.summary, "今日は会議が多かった")
        XCTAssertEqual(resp.summaryAt, 1_719_792_000.0)
    }

    func testCollectionResponseDecodes() throws {
        let json = """
        {
          "items": [
            {
              "id": "col-1",
              "kind": "url",
              "title": "Example Page",
              "note": "後で読む",
              "url": "https://example.com",
              "text": "",
              "imageCount": 0,
              "source": "web",
              "createdAt": 1719792000.0
            },
            {
              "id": "col-2",
              "kind": "image",
              "title": "",
              "note": "",
              "url": "",
              "text": "写真メモ",
              "imageCount": 2,
              "source": "share",
              "createdAt": 1719795600.0
            }
          ]
        }
        """.data(using: .utf8)!
        let resp = try decoder.decode(CollectionResponse.self, from: json)
        XCTAssertEqual(resp.items.count, 2)
        XCTAssertEqual(resp.items[0].kind, "url")
        XCTAssertEqual(resp.items[0].title, "Example Page")
        XCTAssertEqual(resp.items[1].imageCount, 2)
        XCTAssertEqual(resp.items[1].displayTitle, "写真メモ")
    }

    func testPushTokenHexEncode() {
        let data = Data([0xAB, 0xCD, 0x01, 0xFF])
        XCTAssertEqual(PushTokenHex.encode(data), "abcd01ff")
    }

    func testPushTokenHexEncodeEmpty() {
        XCTAssertEqual(PushTokenHex.encode(Data()), "")
    }

    func testLiveActivityStartRegistrationBody() throws {
        let body = PushRegistrationPayload.liveActivityStartToken("abcd01ff")
        XCTAssertEqual(body["token"], "abcd01ff")
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(decoded?["token"], "abcd01ff")
    }

    func testLiveActivityStartRegistrationBodyRejectsEmptyInCaller() {
        XCTAssertEqual(PushRegistrationPayload.liveActivityStartToken("")["token"], "")
    }
}
