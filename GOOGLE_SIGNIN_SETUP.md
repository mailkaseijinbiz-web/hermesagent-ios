# Google サインイン連携 セットアップ手順

iOS / iPad / Mac を「同じ Google アカウントでサインインした端末だけが接続できる」状態にするための設定手順です。

> 構成: **Mac がハブ**(Hermes セッションを保持)で、iPhone / iPad は **Tailscale 経由**で Mac に接続するクライアントです。
> Google サインインは「アクセス認証(ゲート)」として機能します。クラウド同期は使いません — 全端末が同じ Mac に繋がるため、セッションは自動的に共有されます。

設定が終わるまでは **Google 認証はスキップ**され、アプリは従来通り Tailscale 接続のみで動作します(壊れません)。

---

## 1. Google OAuth クライアント ID を作る(あなたの Google アカウントで)

1. [Google Cloud Console](https://console.cloud.google.com/) にアクセス
2. プロジェクトを作成(例: `HermesAgent`)
3. **APIs & Services → OAuth consent screen**
   - User Type: **External**
   - アプリ名・サポートメール等を入力して保存
   - **Test users** に自分の Google メール(接続に使うアカウント)を追加
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**
   - Application type: **iOS**
   - Bundle ID: `com.custom.hermesagent`
   - 作成すると **iOS クライアント ID**(`xxxxxxxx.apps.googleusercontent.com`)が発行される

---

## 2. iOS アプリにクライアント ID を設定

`hermesagent-ios/project.yml` の以下 2 箇所の `REPLACE_WITH_GOOGLE_CLIENT_ID` を、発行されたクライアント ID に置き換えます。

```yaml
GIDClientID: "REPLACE_WITH_GOOGLE_CLIENT_ID.apps.googleusercontent.com"
CFBundleURLTypes:
  - CFBundleTypeRole: Editor
    CFBundleURLSchemes:
      - "com.googleusercontent.apps.REPLACE_WITH_GOOGLE_CLIENT_ID"
```

- `GIDClientID` … クライアント ID をそのまま(`.apps.googleusercontent.com` 込み)
- `CFBundleURLSchemes` … クライアント ID の「**逆順(reversed)**」形式
  - 例: ID が `12345-abc.apps.googleusercontent.com` なら → `com.googleusercontent.apps.12345-abc`

置き換えたら再生成して実機へ:

```bash
cd hermesagent-ios
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodegen generate
open HermesAgent.xcodeproj   # Xcode から Run、または下記 CLI
```

> CLI で実機インストールする場合は、これまでと同じ `xcodebuild ... -sdk iphoneos` → `xcrun devicectl device install app` の手順でOKです。

---

## 3. Mac 側で「許可するアカウント」を設定

1. Mac の HermesCustom アプリ → 右上の **モバイル同期** ボタン(QR が出るポップオーバー)を開く
2. **「Google認証を必須にする」** をオンにする
3. **許可する Google メール** に、接続を許可するアカウント(手順 1 で Test user に入れたメール)を入力
4. **iOS OAuth クライアント ID** に、手順 1 で発行された `xxx.apps.googleusercontent.com` を入力

これで、**そのアカウントかつこのアプリ**でサインインした端末のみ `/api/*` にアクセスできます。

> 🔒 **重要(セキュリティ)**: メールとクライアント ID の**両方**を設定するまで、認証必須をオンにしてもすべての接続を拒否します(fail-closed)。
> クライアント ID(トークンの `aud`)を検証することで、「同じ Google アカウントで別アプリにログインして得た ID トークン」での不正アクセス(audience-confusion / トークン置換)を防ぎます。メールだけの一致では不十分です。

---

## 動作の仕組み(参考)

- iOS は Google サインインで得た **ID トークン**を、毎リクエストの `Authorization: Bearer <token>` で送信
- Mac の `MobileServer` は Google の `tokeninfo` エンドポイントでトークンを検証
  - `iss` が Google / `email_verified` / 期限切れでない / `email` が許可メールと一致 / `aud` が許可クライアントIDと一致、を確認
  - 検証結果はトークン失効までキャッシュ(毎回の通信を回避)
  - 検証失敗・ネットワーク不通時は **401(fail-closed)**
- 許可メールを変更すると、キャッシュ済みトークンにも即時反映されます

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| サインイン画面が出ない | `GIDClientID` が placeholder のまま → 手順 2 を確認 |
| サインイン後に接続が 401 | Mac の「許可する Google メール」がサインインしたアカウントと一致しているか確認 |
| サインインが即閉じる/エラー | `CFBundleURLSchemes` の reversed ID が間違っている可能性 |
| `redirect_uri_mismatch` | OAuth クライアントの種類が **iOS**(Web ではない)か確認 |
