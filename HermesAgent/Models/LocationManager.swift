import Foundation
import CoreLocation
import Combine

/// 今日訪れた場所の1件（到着時刻＋場所名＋座標）。座標は端末に保存し、地図表示用に
/// ユーザー自身の私的Macハブへのみ送る（外部には出さない）。
struct VisitEntry: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var time: Date
    var lat: Double = 0
    var lon: Double = 0
}

/// 位置情報から「今日の足あと」を作る。プライバシー重視：座標は端末内で逆ジオコーディングして
/// **場所名のみ**を保持・送信し、生の座標は Mac ハブに送らない。
/// 自動記録は訪問監視(CLVisit, Always権限が必要)＋アプリ前面化時の現在地取得で行う。
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    /// Set by AppState so summaries can be pushed to the Mac hub.
    weak var apiClient: APIClient?

    // Throttle: skip geocoding when we haven't meaningfully moved (CLGeocoder is rate-limited).
    private var lastGeocodedCoord: CLLocationCoordinate2D?

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "locationLoggingEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "locationLoggingEnabled") }
    }
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var todayVisits: [VisitEntry] = []

    private let visitsKey = "todayVisits"
    private let visitsDateKey = "todayVisitsDate"

    override init() {
        super.init()
        manager.delegate = self
        authStatus = manager.authorizationStatus
        loadToday()
        if enabled { startIfAuthorized() }
    }

    /// 「自宅 → 会社 → サウナ」形式のサマリ（連続重複は除去）。
    var summary: String {
        var names: [String] = []
        for v in todayVisits where names.last != v.name { names.append(v.name) }
        return names.joined(separator: " → ")
    }

    var isAuthorized: Bool {
        authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse
    }

    // MARK: - Enable / disable (privacy toggle)

    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            requestAuth()
            startIfAuthorized()
        } else {
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func requestAuth() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()  // 背景の自動記録に必要
        default: break
        }
    }

    private func startIfAuthorized() {
        guard isAuthorized else { return }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()   // Always権限があれば背景でも到着/出発を記録
    }

    /// 現在地を1回だけ記録（When In Use でも動く前面取得のフォールバック）。
    func recordNow() {
        guard enabled else { return }
        guard isAuthorized else { requestAuth(); return }
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authStatus = status
            if self.enabled { self.startIfAuthorized() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coord = visit.coordinate
        let arrival = visit.arrivalDate == Date.distantPast ? Date() : visit.arrivalDate
        Task { @MainActor in await self.addVisit(coordinate: coord, time: arrival) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coord = loc.coordinate
        Task { @MainActor in await self.addVisit(coordinate: coord, time: Date()) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }

    // MARK: - Visit handling

    private func addVisit(coordinate: CLLocationCoordinate2D, time: Date) async {
        // Throttle: ignore updates within ~120m of the last geocoded point (avoids redundant,
        // rate-limited geocodes and duplicate entries).
        if let last = lastGeocodedCoord,
           CLLocation(latitude: last.latitude, longitude: last.longitude)
             .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 120 {
            return
        }
        lastGeocodedCoord = coordinate
        let name = await reverseGeocode(coordinate)
        rolloverIfNeeded()
        if let last = todayVisits.last, last.name == name { return }   // 連続重複は無視
        todayVisits.append(VisitEntry(name: name, time: time, lat: coordinate.latitude, lon: coordinate.longitude))
        if todayVisits.count > 40 { todayVisits.removeFirst(todayVisits.count - 40) }
        saveToday()
        pushSummary()
    }

    /// Use a FRESH CLGeocoder per call: the shared/serial geocoder cancels an in-flight
    /// request when a second arrives (overlapping addVisit Tasks), degrading to "不明な場所".
    private func reverseGeocode(_ c: CLLocationCoordinate2D) async -> String {
        let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(loc).first
        if let p = placemark {
            return p.name ?? p.areasOfInterest?.first ?? p.thoroughfare ?? p.locality ?? "不明な場所"
        }
        return "不明な場所"
    }

    private func pushSummary() {
        let s = summary
        guard !s.isEmpty, let api = apiClient else { return }
        // Send the per-place coordinates too (valid ones only) so the Mac can draw the
        // footprint on a map. Stays within the user's own private hub.
        let points = todayVisits
            .filter { $0.lat != 0 || $0.lon != 0 }
            .map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon] as [String: Any] }
        Task { await api.pushLocation(summary: s, points: points) }
    }

    // MARK: - Persistence (today only)

    private func rolloverIfNeeded() {
        let today = Self.dayKey(Date())
        if UserDefaults.standard.string(forKey: visitsDateKey) != today {
            todayVisits = []
            UserDefaults.standard.set(today, forKey: visitsDateKey)
            saveToday()
        }
    }
    private func loadToday() {
        rolloverIfNeeded()
        if let data = UserDefaults.standard.data(forKey: visitsKey),
           let v = try? JSONDecoder().decode([VisitEntry].self, from: data) { todayVisits = v }
    }
    private func saveToday() {
        if let data = try? JSONEncoder().encode(todayVisits) {
            UserDefaults.standard.set(data, forKey: visitsKey)
        }
    }
    private static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
