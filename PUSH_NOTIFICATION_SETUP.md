# Push通知（APNs）セットアップ手順

iPhone/iPad に **アプリを閉じていてもプッシュ通知**を届けるための設定です。Mac が「送信元(プロバイダ)」になり、Apple の APNs に通知を送ります。クラウドサーバーは不要です。

## 仕組み
- iOS アプリが APNs から **デバイストークン**を取得 → Mac に登録(`POST /api/push/register`)
- Mac は state.db に**新しいアシスタント応答**が入ると検知し、`.p8` キーで署名した JWT を付けて Apple(`api.sandbox.push.apple.com`)へ送信
- iPhone にバナー通知が届く(アプリが閉じていてもOK)

設定が終わるまでは無効(グレースフル)で、他機能には影響しません。

---

## 1. APNs認証キー(.p8)を作成 — あなたのApple Developerアカウントで（代行不可）

1. [Apple Developer → Certificates, Identifiers & Profiles → Keys](https://developer.apple.com/account/resources/authkeys/list) を開く
2. **「+」** で新規キー作成 → 名前を入力 → **Apple Push Notifications service (APNs)** にチェック → Continue → Register
3. **`AuthKey_XXXXXXXXXX.p8` をダウンロード**(1回だけ・再DL不可なので大切に保管)
4. 画面に表示される **Key ID(10桁)** を控える
5. Team ID は **`576D2UUHH5`**(既に設定済み)

> Bundle ID `com.custom.hermesagent` の Push Notifications capability は、ビルド時に自動で有効化済みです。

## 2. iPhone側 — 通知を許可
- アプリを起動すると通知許可ダイアログが出ます → **許可**
- これでデバイストークンが Mac に登録されます

## 3. Mac側 — キーを設定して有効化
1. ダウンロードした `.p8` を分かりやすい場所に置く（例: `~/.hermes/AuthKey_XXXX.p8`）
2. Mac の HermesCustom → 右上 **モバイル同期** ポップオーバーを開く
3. **「Push通知を有効化」** をオン
4. 入力:
   - **.p8キーのパス**: 例 `/Users/keitayasui/.hermes/AuthKey_XXXX.p8`
   - **Key ID**: 手順1の10桁
   - **Team ID**: `576D2UUHH5`(既定)
   - **Sandbox(開発ビルド)**: **オン**のまま(Xcode/CLIでインストールした開発ビルドは sandbox APNs を使うため)
5. 「登録端末: N台」と出ていれば iPhone のトークン登録済み

## 動作確認
- iPhoneでアプリを**閉じる**(またはバックグラウンド)
- Mac またはもう一台から新しいチャットを送る（=新しいアシスタント応答が state.db に入る）
- iPhone にバナー通知が届けば成功 🎉

## トラブルシューティング
| 症状 | 対処 |
|---|---|
| 通知が来ない | Mac側「登録端末」が1台以上か / .p8パス・Key ID が正しいか確認 |
| `BadDeviceToken` がMacログに出る | Sandboxトグルを切り替える(開発ビルド=ON、TestFlight/配布=OFF) |
| `403 / InvalidProviderToken` | Key ID か Team ID が誤り、または .p8 とKey IDの組が不一致 |
| トークンが登録されない | iPhoneで通知を許可したか / アプリがMacに接続済みか確認 |

> 注意: 本番(App Store/TestFlight)配布ビルドは **Sandboxをオフ**(`api.push.apple.com`)にしてください。今は開発ビルドなので **オン** が正解です。
