import SwiftUI

/// 配分バーの色パレット（領域ごとに循環）。
enum ResourcePalette {
    static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .brown]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

/// 頭のメモリ割り当てを「メモリ使用バー」風に積み上げ表示する。空きは灰色。
struct AllocationBar: View {
    let allocations: [ResourceAllocation]
    var height: CGFloat = 16

    private var total: Int { allocations.reduce(0) { $0 + $1.percent } }

    var body: some View {
        let items = allocations.enumerated().filter { $0.element.percent > 0 }
        let denom = max(total, 100)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(items, id: \.element.id) { idx, a in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ResourcePalette.color(idx))
                        .frame(width: max(3, geo.size.width * CGFloat(a.percent) / CGFloat(denom)))
                }
                if total < 100 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))   // 空き（未割り当て）
                }
            }
        }
        .frame(height: height)
    }
}

/// 「自分のリソース」— 自分をPCに見立て、頭のメモリ割り当て(関心領域ごとの%)と稼働時間を
/// 可視化・調整する。Mac ハブ(/api/self)に保存し、AIの振り返り・助言の文脈にも反映される。
struct SelfResourcesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var allocations: [ResourceAllocation] = []
    @State private var workStart = 9
    @State private var workEnd = 18
    @State private var targetFocus = 0.0
    @State private var loaded = false

    private var total: Int { allocations.reduce(0) { $0 + $1.percent } }

    var body: some View {
        Form {
            Section {
                AllocationBar(allocations: allocations, height: 18)
                    .padding(.vertical, 4)
                HStack {
                    Text("合計 \(total)%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(total == 100 ? .green : (total > 100 ? .red : .orange))
                    Spacer()
                    if total != 100 && !allocations.isEmpty {
                        Button("100%に調整") { normalize() }
                            .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.tint)
                    }
                }
            } header: {
                Text("頭のメモリ割り当て")
            } footer: {
                Text("いま頭の容量を何にどれくらい割いているかの目安。合計100%が目安です。")
            }

            Section {
                ForEach($allocations) { $alloc in
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Circle().fill(colorFor($alloc.wrappedValue)).frame(width: 10, height: 10)
                            TextField("領域名（例: 仕事 / 健康）", text: $alloc.name)
                                .font(.system(size: 14))
                            Text("\(alloc.percent)%")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        Slider(value: percentBinding($alloc), in: 0...100, step: 5)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { allocations.remove(atOffsets: $0) }

                Button {
                    allocations.append(ResourceAllocation(name: "", percent: 10))
                } label: {
                    Label("領域を追加", systemImage: "plus.circle")
                }
            } header: {
                Text("領域ごとの割り当て")
            }

            Section {
                Stepper("開始 \(workStart):00", value: $workStart, in: 0...23)
                Stepper("終了 \(workEnd):00", value: $workEnd, in: 0...23)
                Stepper(targetFocus > 0 ? String(format: "目標集中 %.1f時間/日", targetFocus) : "目標集中 未設定",
                        value: $targetFocus, in: 0...16, step: 0.5)
            } header: {
                Text("稼働時間")
            } footer: {
                Text("1日のうち「自分が稼働している」時間帯と、集中して使いたい目標時間。AIが時間の使い方を助言する基準になります。")
            }
        }
        .navigationTitle("自分のリソース")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { Button("保存") { save() } }
        }
        .task {
            await appState.fetchSelf()
            if !loaded {
                let m = appState.selfModel
                allocations = m.allocations.isEmpty ? Self.defaultAllocations : m.allocations
                workStart = m.workStartHour
                workEnd = m.workEndHour
                targetFocus = m.targetFocusHours
                loaded = true
            }
        }
    }

    // MARK: - Helpers

    private static let defaultAllocations: [ResourceAllocation] = [
        ResourceAllocation(name: "仕事", percent: 40),
        ResourceAllocation(name: "健康", percent: 20),
        ResourceAllocation(name: "家族", percent: 20),
        ResourceAllocation(name: "学習", percent: 20)
    ]

    private func colorFor(_ a: ResourceAllocation) -> Color {
        let idx = allocations.firstIndex(where: { $0.id == a.id }) ?? 0
        return ResourcePalette.color(idx)
    }

    private func percentBinding(_ alloc: Binding<ResourceAllocation>) -> Binding<Double> {
        Binding(get: { Double(alloc.wrappedValue.percent) },
                set: { alloc.wrappedValue.percent = Int($0) })
    }

    /// 合計が**ちょうど100%**になるよう比例配分し、丸め残差を最大の領域へ吸収させる。
    private func normalize() {
        let t = total
        guard t > 0 else { return }
        for i in allocations.indices {
            allocations[i].percent = Int((Double(allocations[i].percent) / Double(t) * 100).rounded())
        }
        let diff = 100 - allocations.reduce(0) { $0 + $1.percent }
        if diff != 0, let idx = allocations.indices.max(by: { allocations[$0].percent < allocations[$1].percent }) {
            allocations[idx].percent = max(0, allocations[idx].percent + diff)
        }
    }

    private func save() {
        let cleaned = allocations.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let m = SelfModel(allocations: cleaned, workStartHour: workStart,
                          workEndHour: workEnd, targetFocusHours: targetFocus)
        Task { await appState.saveSelf(m) }
        dismiss()
    }
}

#Preview {
    NavigationStack { SelfResourcesView() }
        .environmentObject(AppState())
}
