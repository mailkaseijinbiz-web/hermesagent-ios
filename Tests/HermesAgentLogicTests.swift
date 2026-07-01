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

    // MARK: - Mac activity summarization

    private func makeMacEntry(
        id: String,
        appName: String,
        start: TimeInterval,
        duration: TimeInterval,
        kind: String = "app"
    ) -> MacActivityEntry {
        MacActivityEntry(
            id: id,
            kind: kind,
            appName: appName,
            bundleId: nil,
            label: appName,
            windowTitle: nil,
            startTime: start,
            endTime: start + duration
        )
    }

    func testMacActivitySummarizerMergesSameAppEntries() {
        let base: TimeInterval = 1_700_000_000
        var entries: [MacActivityEntry] = []
        for i in 0..<20 {
            let start = base + Double(i) * 600
            entries.append(makeMacEntry(id: "e\(i)", appName: "Xcode", start: start, duration: 300))
        }

        let summary = MacActivitySummarizer.summarize(entries)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.rawEntryCount, 20)
        XCTAssertEqual(summary?.apps.count, 1)
        XCTAssertEqual(summary?.apps[0].appName, "Xcode")
        XCTAssertEqual(summary?.apps[0].sessionCount, 1)
        XCTAssertEqual(summary!.totalDuration, Double(20 * 300), accuracy: 0.1)
    }

    func testMacActivitySummarizerCapsAppsWithOtherBucket() {
        let base: TimeInterval = 1_700_000_000
        let appNames = ["AppA", "AppB", "AppC", "AppD", "AppE", "AppF", "AppG"]
        var entries: [MacActivityEntry] = []
        for (idx, name) in appNames.enumerated() {
            let duration = Double(700 - idx * 100)
            entries.append(makeMacEntry(id: "a\(idx)", appName: name, start: base + Double(idx) * 3600, duration: duration))
        }

        let summary = MacActivitySummarizer.summarize(entries, maxApps: 5)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.apps.count, 6)
        XCTAssertEqual(summary?.apps.last?.appName, "その他")
        XCTAssertTrue(summary?.apps.contains(where: { $0.appName == "AppA" }) ?? false)
        XCTAssertFalse(summary?.apps.contains(where: { $0.appName == "AppG" }) ?? true)
    }

    @MainActor
    func testLifeLogTimelineEmitsSingleMacSummary() {
        let base: TimeInterval = 1_700_000_000
        var mac: [MacActivityEntry] = []
        for i in 0..<10 {
            mac.append(makeMacEntry(id: "m\(i)", appName: "Safari", start: base + Double(i) * 120, duration: 60))
        }

        let store = LifeLogStore(defaults: UserDefaults(suiteName: "test.lifelog.\(UUID().uuidString)")!)
        let items = store.timeline(visits: [], memos: [], macActivities: mac)
        let macItems = items.filter {
            if case .macSummary = $0 { return true }
            if case .mac = $0 { return true }
            return false
        }
        XCTAssertEqual(macItems.count, 1)
        if case .macSummary(let s) = macItems[0] {
            XCTAssertEqual(s.rawEntryCount, 10)
            XCTAssertEqual(s.apps.count, 1)
        } else {
            XCTFail("Expected macSummary item")
        }
    }

    // MARK: - Home date navigation

    func testHomeDateHelpersDayKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: 12)
        let date = cal.date(from: comps)!
        XCTAssertEqual(HomeDateHelpers.dayKey(date, calendar: cal), "2026-07-01")
    }

    func testHomeDateHelpersNavigateDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 15)
        let date = cal.date(from: comps)!
        let next = HomeDateHelpers.navigate(date, scope: .day, direction: 1, calendar: cal)
        XCTAssertEqual(HomeDateHelpers.dayKey(next, calendar: cal), "2026-07-16")
    }

    func testHomeDateHelpersWeekDaysCount() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 15)
        let date = cal.date(from: comps)!
        XCTAssertEqual(HomeDateHelpers.weekDays(containing: date, calendar: cal).count, 7)
    }

    func testLifeLogArchiveRollover() {
        let memo = LifeLogMemo(text: "昨日のメモ", time: Date())
        let result = LifeLogArchiveLogic.rollover(
            todayMemos: [memo],
            storedDateKey: "2026-06-30",
            todayKey: "2026-07-01",
            archive: [:]
        )
        XCTAssertTrue(result.todayMemos.isEmpty)
        XCTAssertEqual(result.archive["2026-06-30"]?.count, 1)
        XCTAssertEqual(result.newDateKey, "2026-07-01")
    }

    func testVisitArchiveRollover() {
        let visit = VisitEntry(name: "自宅", time: Date())
        let result = VisitArchiveLogic.rollover(
            todayVisits: [visit],
            storedDateKey: "2026-06-30",
            todayKey: "2026-07-01",
            archive: [:]
        )
        XCTAssertTrue(result.todayVisits.isEmpty)
        XCTAssertEqual(result.archive["2026-06-30"]?.first?.name, "自宅")
    }

    func testMacActivitiesOnDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: 10)
        let day1 = cal.date(from: comps)!
        comps.day = 2
        let day2 = cal.date(from: comps)!
        let entries = [
            MacActivityEntry(id: "a1", kind: "app", appName: "Xcode", bundleId: nil,
                             label: "", windowTitle: nil,
                             startTime: day1.timeIntervalSince1970, endTime: day1.timeIntervalSince1970 + 60),
            MacActivityEntry(id: "a2", kind: "app", appName: "Safari", bundleId: nil,
                             label: "", windowTitle: nil,
                             startTime: day2.timeIntervalSince1970, endTime: day2.timeIntervalSince1970 + 60),
        ]
        let range = HomeDateHelpers.dayRange(for: day1, calendar: cal)
        let filtered = entries.filter { $0.startDate >= range.start && $0.startDate < range.end }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "a1")
    }
}
