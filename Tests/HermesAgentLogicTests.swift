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

    func testIntentionCardDecodesOptionalRationale() throws {
        let json = """
        {
          "id": "int-1",
          "title": "散歩15分",
          "subtitle": "軽く回復",
          "icon": "leaf.fill",
          "kind": "recover",
          "action": { "type": "none" },
          "rationale": "昨日の会議が続いたので体を動かす"
        }
        """.data(using: .utf8)!
        let card = try decoder.decode(IntentionCard.self, from: json)
        XCTAssertEqual(card.id, "int-1")
        XCTAssertEqual(card.rationale, "昨日の会議が続いたので体を動かす")
    }

    func testIntentionCardDecodesWithoutRationale() throws {
        let json = """
        {
          "id": "int-2",
          "title": "今日の1つ",
          "subtitle": "資料を30分",
          "icon": "checklist",
          "kind": "focus",
          "action": { "type": "chat", "chatPrompt": "資料の骨子を整理して" }
        }
        """.data(using: .utf8)!
        let card = try decoder.decode(IntentionCard.self, from: json)
        XCTAssertEqual(card.id, "int-2")
        XCTAssertNil(card.rationale)
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

    func testHubURLNormalizeTrimsAndKeepsPort() {
        XCTAssertEqual(
            HubURL.normalize("  http://mac.tailfc8906.ts.net:9119/  "),
            "http://mac.tailfc8906.ts.net:9119"
        )
    }

    func testHubURLNormalizeAddsScheme() {
        XCTAssertEqual(HubURL.normalize("192.168.1.5:9119"), "http://192.168.1.5:9119")
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
        kind: String = "app",
        windowTitle: String? = nil,
        label: String? = nil
    ) -> MacActivityEntry {
        MacActivityEntry(
            id: id,
            kind: kind,
            appName: appName,
            bundleId: nil,
            label: label ?? appName,
            windowTitle: windowTitle,
            url: nil,
            startTime: start,
            endTime: start + duration
        )
    }

    func testMacWorkFocusPrefersWindowTitleOverTool() {
        let entry = makeMacEntry(
            id: "1",
            appName: "Cursor",
            start: 0,
            duration: 3600,
            windowTitle: "HomeView.swift — hermesagent-ios",
            label: "Cursor — HomeView.swift — hermesagent-ios"
        )
        XCTAssertEqual(MacWorkFocus.workTitle(for: entry), "HomeView.swift — hermesagent-ios")
        XCTAssertEqual(MacWorkFocus.subtitle(for: entry), "Cursor")
    }

    func testMacWorkFocusUsesBrowserPageTitle() {
        let entry = makeMacEntry(
            id: "1",
            appName: "Google Chrome",
            start: 0,
            duration: 600,
            windowTitle: "Swift Documentation - Google Chrome",
            label: "Google Chrome — Swift Documentation - Google Chrome"
        )
        XCTAssertEqual(MacWorkFocus.workTitle(for: entry), "Swift Documentation")
    }

    func testMacActivitySummarizerMergesSameWorkFocusEntries() {
        let base: TimeInterval = 1_700_000_000
        var entries: [MacActivityEntry] = []
        for i in 0..<20 {
            let start = base + Double(i) * 600
            entries.append(makeMacEntry(
                id: "e\(i)",
                appName: "Cursor",
                start: start,
                duration: 300,
                windowTitle: "HomeView.swift — hermesagent-ios",
                label: "Cursor — HomeView.swift — hermesagent-ios"
            ))
        }

        let summary = MacActivitySummarizer.summarize(entries)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.rawEntryCount, 20)
        XCTAssertEqual(summary?.apps.count, 1)
        XCTAssertEqual(summary?.apps[0].workTitle, "HomeView.swift — hermesagent-ios")
        XCTAssertEqual(summary?.apps[0].toolName, "Cursor")
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
        XCTAssertEqual(summary?.apps.last?.workTitle, "その他")
        XCTAssertTrue(summary?.apps.contains(where: { $0.workTitle == "AppA" }) ?? false)
        XCTAssertFalse(summary?.apps.contains(where: { $0.workTitle == "AppG" }) ?? false)
    }

    func testPhotoDescriptionFormatting() {
        XCTAssertEqual(
            PhotoSceneTagger.formatDescription(tags: ["食事", "カフェ"], ocrText: "MENU"),
            "食事、カフェの写真。写っている文字: MENU"
        )
        XCTAssertEqual(
            PhotoSceneTagger.formatDescription(tags: ["風景"], ocrText: ""),
            "風景の写真"
        )
    }

    @MainActor
    func testLifeLogTimelineIncludesPhotos() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = PhotoLogEntry(id: "asset-1", time: base, label: "シーン: 食事", mediaKind: "image")
        let store = LifeLogStore(defaults: UserDefaults(suiteName: "test.lifelog.photo.\(UUID().uuidString)")!)
        let items = store.timeline(visits: [], memos: [], macActivities: [], photoEntries: [photo])
        XCTAssertEqual(items.count, 1)
        if case .photo(let p) = items[0] {
            XCTAssertEqual(p.label, "シーン: 食事")
        } else {
            XCTFail("Expected photo item")
        }
    }

    @MainActor
    func testLifeLogTimelineEmitsIndividualMacEntriesWhenFewApps() {
        let base: TimeInterval = 1_700_000_000
        var mac: [MacActivityEntry] = []
        for i in 0..<10 {
            mac.append(makeMacEntry(id: "m\(i)", appName: "Safari", start: base + Double(i) * 120, duration: 60))
        }

        let store = LifeLogStore(defaults: UserDefaults(suiteName: "test.lifelog.\(UUID().uuidString)")!)
        let items = store.timeline(visits: [], memos: [], macActivities: mac)
        let macItems = items.compactMap { item -> MacActivityEntry? in
            if case .mac(let a) = item { return a }
            return nil
        }
        XCTAssertEqual(macItems.count, 10)
        XCTAssertFalse(items.contains { if case .macSummary = $0 { return true }; return false })
    }

    @MainActor
    func testLifeLogTimelineEmitsMacSummaryWhenManyApps() {
        let base: TimeInterval = 1_700_000_000
        var mac: [MacActivityEntry] = []
        for i in 0..<6 {
            mac.append(makeMacEntry(id: "m\(i)", appName: "App\(i)", start: base + Double(i) * 120, duration: 60))
        }

        let store = LifeLogStore(defaults: UserDefaults(suiteName: "test.lifelog.many.\(UUID().uuidString)")!)
        let items = store.timeline(visits: [], memos: [], macActivities: mac)
        let macItems = items.filter {
            if case .macSummary = $0 { return true }
            if case .mac = $0 { return true }
            return false
        }
        XCTAssertEqual(macItems.count, 1)
        if case .macSummary(let s) = macItems[0] {
            XCTAssertEqual(s.rawEntryCount, 6)
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

    func testLifeLogSyncNormalizeMacMemoDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 1995, month: 7, day: 1, hour: 16, minute: 32)
        let wrongDay = cal.date(from: comps)!
        comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 2)
        let target = cal.date(from: comps)!
        let memo = LifeLogMemo(id: "m1", text: "たこ焼き", time: wrongDay, source: "mac", pageTitle: "たこ焼き", mediaKind: "image")
        let fixed = LifeLogSyncLogic.normalizeMacMemosForDay([memo], day: target, calendar: cal)
        XCTAssertEqual(fixed.count, 1)
        XCTAssertTrue(cal.isDate(fixed[0].time, inSameDayAs: target))
        XCTAssertEqual(cal.component(.hour, from: fixed[0].time), 16)
        XCTAssertEqual(fixed[0].timelineDetail, "たこ焼き")
    }

    func testLifeLogSyncMergeMemosDedupesById() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let local = [LifeLogMemo(id: "m1", text: "ローカル", time: base, source: "ios")]
        let remote = [
            LifeLogMemo(id: "m1", text: "ローカル（更新）", time: base, source: "ios"),
            LifeLogMemo(id: "m2", text: "Macメモ", time: base.addingTimeInterval(60), source: "mac"),
        ]
        let merged = LifeLogSyncLogic.mergeMemos(existing: local, incoming: remote)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first(where: { $0.id == "m1" })?.text, "ローカル（更新）")
    }

    func testLifeLogSyncBucketsMacActivitiesByDay() {
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
        let buckets = LifeLogSyncLogic.bucketMacActivities(entries, calendar: cal)
        XCTAssertEqual(buckets["2026-07-01"]?.count, 1)
        XCTAssertEqual(buckets["2026-07-02"]?.count, 1)
    }

    @MainActor
    func testLifeLogStoreMergesMacMemosIntoTimeline() {
        let defaults = UserDefaults(suiteName: "test.lifelog.sync.\(UUID().uuidString)")!
        let store = LifeLogStore(defaults: defaults)
        let base = Date()
        let key = HomeDateHelpers.dayKey(base)
        store.ingestMacMemos([LifeLogMemo(id: "mac-1", text: "Macから", time: base, source: "mac")], dayKey: key)
        let memos = store.memos(on: base)
        XCTAssertEqual(memos.count, 1)
        XCTAssertEqual(memos[0].text, "Macから")
    }

    @MainActor
    func testLifeLogDayCoverPersists() {
        let defaults = UserDefaults(suiteName: "test.lifelog.cover.\(UUID().uuidString)")!
        let store = LifeLogStore(defaults: defaults)
        let day = Date()
        let memo = LifeLogMemo(id: "m1", text: "表紙候補", time: day)
        let item = LifeLogItem.memo(memo)
        store.setDayCover(item, for: day)
        let items = store.timeline(for: day, visits: [], photoEntries: [])
        XCTAssertEqual(store.resolveCover(in: items + [item], for: day)?.id, item.id)
        store.clearDayCover(for: day)
        XCTAssertNil(store.resolveCover(in: items, for: day))
    }

    @MainActor
    func testMacActivitiesOnDate() async {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var comps = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: 10)
        let day1 = cal.date(from: comps)!
        comps.day = 2
        let day2 = cal.date(from: comps)!
        let defaults = UserDefaults(suiteName: "test.lifelog.mac.\(UUID().uuidString)")!
        let store = LifeLogStore(defaults: defaults)
        store.ingestMacActivities([
            MacActivityEntry(id: "a1", kind: "app", appName: "Xcode", bundleId: nil,
                             label: "", windowTitle: nil,
                             startTime: day1.timeIntervalSince1970, endTime: day1.timeIntervalSince1970 + 60),
            MacActivityEntry(id: "a2", kind: "app", appName: "Safari", bundleId: nil,
                             label: "", windowTitle: nil,
                             startTime: day2.timeIntervalSince1970, endTime: day2.timeIntervalSince1970 + 60),
        ])
        XCTAssertEqual(store.macActivities(on: day1).count, 1)
        XCTAssertEqual(store.macActivities(on: day1)[0].id, "a1")
    }

    func testLifeLogSyncMergeHealthPrefersLocalNonZero() {
        let local = DayHealthMetrics(steps: 5000, activeEnergy: 200, restingHR: 0, sleepHours: 0, bodyMassKg: 0)
        let remote = MacDayRecord(
            date: "2026-07-02",
            steps: 8000,
            activeEnergyKcal: 350,
            restingHeartRate: 62,
            sleepHours: 7.2,
            bodyMassKg: 70.5,
            locations: "自宅 → オフィス"
        )
        let merged = LifeLogSyncLogic.mergeHealth(local: local, remote: remote)
        XCTAssertEqual(merged.steps, 5000)
        XCTAssertEqual(merged.activeEnergy, 200)
        XCTAssertEqual(merged.restingHR, 62)
        XCTAssertEqual(merged.sleepHours, 7.2)
        XCTAssertEqual(merged.bodyMassKg, 70.5)
    }

    func testLifeLogSyncMergeHealthFillsEmptyLocalFromMac() {
        let local = DayHealthMetrics.empty
        let remote = MacDayRecord(
            date: "2026-07-02",
            steps: 8200,
            activeEnergyKcal: nil,
            restingHeartRate: 58,
            sleepHours: 6.5,
            bodyMassKg: nil,
            locations: ""
        )
        let merged = LifeLogSyncLogic.mergeHealth(local: local, remote: remote)
        XCTAssertEqual(merged.steps, 8200)
        XCTAssertEqual(merged.restingHR, 58)
        XCTAssertEqual(merged.sleepHours, 6.5)
    }

    @MainActor
    func testLifeLogStoreIngestMacDayRecord() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let day = cal.date(from: DateComponents(calendar: cal, year: 2026, month: 7, day: 2))!
        let defaults = UserDefaults(suiteName: "test.lifelog.history.\(UUID().uuidString)")!
        let store = LifeLogStore(defaults: defaults)
        store.ingestMacDayRecord(MacDayRecord(
            date: "2026-07-02",
            steps: 9000,
            activeEnergyKcal: 400,
            restingHeartRate: 60,
            sleepHours: 7.0,
            bodyMassKg: nil,
            locations: "自宅 → カフェ → オフィス"
        ))
        let record = store.macDayRecord(on: day)
        XCTAssertEqual(record?.steps, 9000)
        XCTAssertEqual(record?.locations, "自宅 → カフェ → オフィス")
    }

    // MARK: - News prose serendipity

    func testNewsProseSerendipitySectionInWeeklyReview() {
        let text = """
        振り返り
        今週は会議が多かった。

        今週の意外なつながり
        サウナの記録と健康目標が重なっていた。
        """
        let blocks = NewsProseParser.parse(text, context: .weeklyReview)
        XCTAssertTrue(blocks.contains(.serendipityHeading("今週の意外なつながり")))
        XCTAssertTrue(blocks.contains(.serendipityCard("サウナの記録と健康目標が重なっていた。")))
    }

    func testNewsProseSerendipityNotInBriefContext() {
        let blocks = NewsProseParser.parse("つながり\n本文", context: .brief)
        XCTAssertTrue(blocks.contains(.heading("つながり")))
        XCTAssertFalse(blocks.contains(where: { if case .serendipityHeading = $0 { return true }; return false }))
    }

    func testLifeLogOneLinerIgnoresShortMacAndWindowTitles() {
        var mac = MacActivityEntry(
            id: "a", kind: "app", appName: "Cursor", bundleId: nil,
            label: "Cursor — NextFTP", windowTitle: "NextFTP",
            startTime: 0, endTime: 120
        )
        let items: [LifeLogItem] = [
            .mac(mac),
            .photo(PhotoLogEntry(id: "p1", time: Date(), label: "カフェ", mediaKind: "image")),
            .photo(PhotoLogEntry(id: "p2", time: Date(), label: "街", mediaKind: "image")),
        ]
        let line = LifeLogOneLiner.compose(items: items, metrics: DayHealthMetrics(steps: 6200))
        XCTAssertNotNil(line)
        XCTAssertFalse(line?.contains("NextFTP") ?? true)
        XCTAssertTrue(line?.contains("写真2枚") ?? false)
        XCTAssertTrue(line?.contains("歩数") ?? false)
    }

    func testLifeLogOneLinerIncludesLongMacByAppNameOnly() {
        let mac = MacActivityEntry(
            id: "a", kind: "app", appName: "Cursor", bundleId: nil,
            label: "Cursor — NextFTP", windowTitle: "NextFTP",
            startTime: 0, endTime: 3600
        )
        let line = LifeLogOneLiner.compose(items: [.mac(mac)], metrics: .empty)
        XCTAssertEqual(line, "HomeView.swift — NextFTP 1時間。")
    }

    // MARK: - Evening reflection

    func testEveningReflectionFallbackOneLiner() {
        XCTAssertEqual(
            EveningReflectionLogic.fallbackOneLiner(pickedLabel: "カフェ", feeling: "落ち着いた"),
            "カフェ。落ち着いた"
        )
        XCTAssertEqual(
            EveningReflectionLogic.fallbackOneLiner(pickedLabel: "", feeling: "充実"),
            "充実"
        )
        XCTAssertEqual(
            EveningReflectionLogic.fallbackOneLiner(pickedLabel: "散歩", feeling: ""),
            "散歩"
        )
    }

    func testEveningReflectionFallbackAiReflection() {
        let text = EveningReflectionLogic.fallbackAiReflection(
            pickedLabel: "カフェ",
            feeling: "落ち着いた",
            dayHint: "徒歩が多い一日。"
        )
        XCTAssertTrue(text.contains("カフェ"))
        XCTAssertTrue(text.contains("落ち着いた"))
        XCTAssertTrue(text.contains("徒歩"))
    }

    // MARK: - Mobility (GPS visit segments)

    func testMobilityClassifyWalkBikeTrain() {
        XCTAssertEqual(MobilityAnalyzer.classify(speedKmh: 4, distanceMeters: 500), .walk)
        XCTAssertEqual(MobilityAnalyzer.classify(speedKmh: 15, distanceMeters: 2000), .bike)
        XCTAssertEqual(MobilityAnalyzer.classify(speedKmh: 40, distanceMeters: 8000), .train)
        XCTAssertNil(MobilityAnalyzer.classify(speedKmh: 1, distanceMeters: 200))
        XCTAssertNil(MobilityAnalyzer.classify(speedKmh: 5, distanceMeters: 50))
    }

    func testMobilityAnalyzeSegments() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: h, minute: m)
            return cal.date(from: c)!
        }
        // Shinjuku → Shibuya ~4km in 50min ≈ 4.8 km/h → walk
        let visits = [
            VisitEntry(name: "新宿", time: at(9, 0), lat: 35.6896, lon: 139.7006),
            VisitEntry(name: "渋谷", time: at(9, 50), lat: 35.6580, lon: 139.7016),
            // ~15km in 30min ≈ 30 km/h → train
            VisitEntry(name: "横浜", time: at(10, 20), lat: 35.4657, lon: 139.6220),
        ]
        let totals = MobilityAnalyzer.analyze(visits: visits)
        XCTAssertGreaterThan(totals.walkSeconds, 0)
        XCTAssertGreaterThan(totals.walkMeters, 1000)
        XCTAssertGreaterThan(totals.trainSeconds, 0)
        XCTAssertGreaterThan(totals.trainMeters, 5000)
        XCTAssertNotNil(totals.summaryLine())
    }

    func testVisitTimelineComposerCollapsesTrainTransit() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: h, minute: m)
            return cal.date(from: c)!
        }
        let visits = [
            VisitEntry(name: "自宅", time: at(8, 0), lat: 35.6896, lon: 139.7006),
            VisitEntry(name: "品川", time: at(8, 35), lat: 35.6284, lon: 139.7387),
            VisitEntry(name: "大井町", time: at(8, 42), lat: 35.6063, lon: 139.7347),
            VisitEntry(name: "オフィス", time: at(9, 10), lat: 35.6580, lon: 139.7016),
        ]
        let items = VisitTimelineComposer.compose(visits: visits, now: at(18, 0))
        let stops = items.compactMap { item -> String? in
            if case .visit(let v, _) = item { return v.name }
            return nil
        }
        XCTAssertEqual(stops, ["自宅", "オフィス"])
        XCTAssertTrue(items.contains { if case .mobility = $0 { return true }; return false })
    }

    func testVisitTimelineComposerCollapsesWalkingGeocodeNoise() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: h, minute: m)
            return cal.date(from: c)!
        }
        let baseLat = 35.6700
        let baseLon = 139.7700
        let visits = [
            VisitEntry(name: "中央4丁目1-4", time: at(1, 8), lat: baseLat, lon: baseLon),
            VisitEntry(name: "中央4丁目4", time: at(1, 13), lat: baseLat + 0.0003, lon: baseLon + 0.0002),
            VisitEntry(name: "中央4丁目1-4", time: at(1, 24), lat: baseLat + 0.0005, lon: baseLon + 0.0004),
            VisitEntry(name: "中央4丁目4", time: at(1, 35), lat: baseLat + 0.0008, lon: baseLon + 0.0006),
            VisitEntry(name: "中央4丁目1-4", time: at(1, 44), lat: baseLat + 0.0010, lon: baseLon + 0.0008),
        ]
        let items = VisitTimelineComposer.compose(visits: visits, now: at(1, 50))
        XCTAssertEqual(items.filter { if case .visit = $0 { return true }; return false }.count, 0)
        guard case .mobility(let m) = items.first else {
            return XCTFail("expected mobility row")
        }
        XCTAssertEqual(m.mode, .walk)
        XCTAssertGreaterThanOrEqual(m.duration, 30 * 60)
    }

    func testVisitTimelineComposerKeepsShortLocalStop() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        func at(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(calendar: cal, year: 2026, month: 7, day: 1, hour: h, minute: m)
            return cal.date(from: c)!
        }
        let visits = [
            VisitEntry(name: "自宅", time: at(10, 0), lat: 35.6896, lon: 139.7006),
            VisitEntry(name: "コンビニ", time: at(10, 5), lat: 35.6898, lon: 139.7008),
            VisitEntry(name: "自宅", time: at(10, 12), lat: 35.6896, lon: 139.7006),
        ]
        let stops = VisitTimelineComposer.significantStops(visits, now: at(18, 0)).map(\.name)
        XCTAssertEqual(stops, ["自宅", "コンビニ", "自宅"])
    }
}
