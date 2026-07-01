# App Groups セットアップ（Share Extension）

## 識別子一覧（`Shared/AppIdentifiers.swift` と一致）

| 種類 | Identifier |
|------|------------|
| メイン App ID | `com.custom.hermesagent` |
| Share Extension | `com.custom.hermesagent.share` |
| Widget | `com.custom.hermesagent.widget` |
| App Group | `group.com.custom.hermesagent` |

## Portal で「not available」になる場合

App ID / App Group は **全世界で一意** です。Portal で登録できないときは次を確認してください。

1. **Identifiers 一覧** — 同じ Apple ID / Team の下に **既に登録済み** ではないか（登録済みなら「+」で新規作成せず、既存を編集）
2. **別 Team** — Personal Team と Organization Team で ID が分かれている
3. **他者が取得済み** — `com.custom.*` はサンプル用で他アカウントが先に取っていることが多い。その場合は **Apple 側では取得不可**（Bundle ID を変えるか、所有アカウントで開発する）

## 手順

1. App Group `group.com.custom.hermesagent` を登録（または既存を確認）
2. App IDs: `com.custom.hermesagent` / `.share` / `.widget` を登録
3. **メイン App ID** (`com.custom.hermesagent`) で次も有効化（entitlements と一致必須）:
   - **App Groups** → `group.com.custom.hermesagent`
   - **Push Notifications**（`aps-environment` 用。未設定だと起動直後 **SIGKILL** になることがある）
   - **HealthKit**（`com.apple.developer.healthkit` 用。同上）
4. プロビジョニングプロファイルを更新（Xcode → Signing で Team 再選択 → Clean Build）
5. iPhone: **設定 → プライバシーとセキュリティ → デベロッパモード** をオン
6. 端末から古い Hermes を削除 → Xcode **⇧⌘K** → **⌘R**

## 起動直後に SIGKILL になる場合

| 原因 | 対処 |
|------|------|
| App ID に HealthKit / Push が無い | Portal で Capability を追加 → プロファイル再生成 |
| デベロッパモード OFF | iPhone で有効化（再起動を求められたら従う） |
| 古い署名の残骸 | アプリ削除 → Clean Build → 再インストール |
| ケーブル / 信頼 | ロック解除・USB 接続・「この Mac を信頼」 |

## ビルドだけ先に進める

App Groups 未設定の間は `SKIP_SHARE=1 ./install_ios.sh` でメインアプリのみインストール可能です。
