import SwiftUI

/// 「自分について」— 好きなもの・目標・価値観・メモを登録する画面。
/// これらは AI の助言の「基準（北極星）」として、デイリーブリーフ生成や会話の文脈に注入される。
/// データは Mac ハブ（/api/profile）に保存（端末ローカル、iCloud非同期）。
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var goals = ""
    @State private var likes = ""
    @State private var values = ""
    @State private var notes = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("例: 健康になりたい / 体重を5kg減らす", text: $goals, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("めざしたいこと（目標）")
            } footer: {
                Text("AIがアドバイスする際の到達点になります。")
            }

            Section("好きなもの") {
                TextField("例: サウナ / コーヒー / 朝の散歩", text: $likes, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("大事にしている価値観") {
                TextField("例: 家族との時間 / 学び続けること", text: $values, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section {
                TextField("AIに知っておいてほしいことを自由に", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("メモ")
            } footer: {
                Text("ここに書いた内容は、毎日の振り返りやチャットでAIが踏まえて助言します。")
            }
        }
        .navigationTitle("自分について")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
            }
        }
        .task {
            await appState.fetchProfile()
            if !loaded {
                let p = appState.personalProfile
                goals = p.goals; likes = p.likes; values = p.values; notes = p.notes
                loaded = true
            }
        }
    }

    private func save() {
        let p = PersonalProfile(likes: likes, goals: goals, values: values, notes: notes)
        Task { await appState.saveProfile(p) }
        dismiss()
    }
}

#Preview {
    NavigationStack { ProfileView() }
        .environmentObject(AppState())
}
