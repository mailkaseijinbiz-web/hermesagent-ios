import SwiftUI
import MapKit

// MARK: - 外出ルート（Macの LocationDayRouteView 相当）
// その日の訪問（座標つき）を地図のポリライン＋番号マーカーで表示する。

struct DayRouteView: View {
    let visits: [VisitEntry]
    /// 見出し（週/月ビューから使うときは「外出ルート（週）」等に差し替える）。
    var title: String = "外出ルート"

    @State private var camera: MapCameraPosition = .automatic

    private var located: [VisitEntry] {
        visits.filter { $0.lat != 0 || $0.lon != 0 }
    }

    private var routeText: String {
        var names: [String] = []
        for v in visits where names.last != v.name { names.append(v.name) }
        return names.joined(separator: " → ")
    }

    var body: some View {
        if located.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 12))
                        .foregroundStyle(.teal)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    if located.count >= 2 {
                        MapPolyline(coordinates: located.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        })
                        .stroke(Color.teal.opacity(0.8),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(Array(located.enumerated()), id: \.element.id) { idx, v in
                        Annotation(v.name, coordinate:
                            CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon)) {
                            ZStack {
                                Circle()
                                    .fill(Color.teal)
                                    .frame(width: 22, height: 22)
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        }
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .allowsHitTesting(true)

                if !routeText.isEmpty {
                    Text(routeText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color.teal.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.teal.opacity(0.12), lineWidth: 0.5)
            )
        }
    }
}
