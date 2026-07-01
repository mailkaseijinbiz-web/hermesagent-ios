# App Groups セットアップ（Share Extension）

HermesAgent の Share Extension は App Group `group.com.custom.hermesagent` 経由でメインアプリとデータを共有します。実機ビルドで Share Extension を含める場合は、以下を Developer Portal で設定してください。

## 1. Apple Developer Portal

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources) を開く
2. **Identifiers** → メインアプリ `com.custom.hermesagent` を選択（または作成）
3. **Capabilities** → **App Groups** を有効化 → `group.com.custom.hermesagent` を追加
4. 同様に Share Extension の Bundle ID（`com.custom.hermesagent.HermesAgentShare`）でも App Groups を有効化し、**同じ** `group.com.custom.hermesagent` を追加
5. Widget を使う場合は Widget の Bundle ID も同様

## 2. プロビジョニングプロファイルの再生成

App Groups を追加・変更したら、該当する **Development / Distribution** プロファイルを再生成し、Xcode または `install_ios.sh` が参照するプロファイルを更新してください。

## 3. ビルド

```bash
# project.yml から生成（Share Extension 込み。SKIP_SHARE は使わない）
xcodegen generate
./install_ios.sh
```

`SKIP_SHARE=1` は App Groups 未設定のプロビジョニング向けの回避策です。Share Extension を使う本番ビルドでは **設定しない** でください。

## 4. 確認

- `HermesAgent/HermesAgent.entitlements` と `HermesAgentShare/HermesAgentShare.entitlements` に `group.com.custom.hermesagent` があること
- `Shared/SharedStore.swift` の `appGroup` と一致していること
