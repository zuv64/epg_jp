# epg_jp

J:COM（ジェイコム）が公開している番組表（EPG）データを、GitHub Actionsで定期的に自動取得・保存するリポジトリです。

## 何をしているか

J:COMの公開API（`tvguide.myjcom.jp`）から、地上波・BS・CSの番組表データをチャンネル・日付ごとに取得し、`data/epg/` 配下にJSONファイルとして保存しています。GitHub Actionsのスケジュール実行により、人手を介さず自動的にデータが蓄積されていきます。

## 収集しているデータ

- 対象チャンネル: 331局（地上波・BS・CS）
- 対象期間: 実行時点から7日分（当日〜6日後）の番組表
- チャンネル一覧: [data/channels.json](data/channels.json)（`siteId`・地域・リモコン番号などを保持）

### 地域をまたぐチャンネルの扱い

日本テレビ・テレビ朝日・TBS・テレビ東京・フジテレビなどの関東キー局は、複数の地域（東京・神奈川・埼玉・千葉・群馬・茨城・栃木）で共通に受信できます。このリポジトリでは、そうしたチャンネルの実データを**地域ごとに複製して保存**しています（同じ番組データが複数の地域フォルダに入ります）。

## 出力形式

```
data/epg/<地域名>/<siteId>/<yyyyMMdd>.json
```

例: `data/epg/東京/2_1040_32738/20260917.json`（東京・日本テレビ・2026年9月17日分）

各JSONファイルの中身は、その日・そのチャンネルの番組情報（番組ID・タイトル・開始/終了時刻・概要など）の配列です。

### `siteId` の構造

`siteId` は `<channelType>_<channelId>_<networkId>` の形式で、J:COMの公開EPG API（`getEpgInfo`の`channels`パラメータ）にそのまま渡せるチャンネル識別子です。

- `channelType`: チャンネル種別。`2`=地上波、`3`=BS、`120`=CS
- `channelId`: J:COM内部のチャンネルID。地上波の場合はレコーダー側`channelList`の`channel_id`とも一致する（例: 東京地区で日テレ=1040、TBS=1048など）
- `networkId`: 放送ネットワークID

例えば `2_1040_32738` なら「地上波・チャンネルID 1040（日本テレビ）・ネットワークID 32738」を表します。チャンネルごとの対応関係は [data/channels.json](data/channels.json) を参照してください。

## 実行の仕組み

- [.github/workflows/fetch-epg.yml](.github/workflows/fetch-epg.yml) がGitHub Actions上で **2時間おき（1日12回、JST 0,2,4,…,22時）** に実行されます。
- 1回の実行では、全チャンネル×7日分のタスク（2317件）のうち580件だけを処理します（J:COMのAPIに負荷をかけすぎないよう、1回のリクエストにつき1チャンネル×1日分のみ取得し、リクエスト間隔を空けています）。
- 処理位置は [data/state.json](data/state.json) の`cursor`で管理され、末尾まで進んだら先頭に戻ってループします。4回の実行（約8時間）で全チャンネル×7日分が一巡し、1日で3周する計算です。
- 同じチャンネル・同じ日付のデータは、実行のたびに最新の内容で上書きされます。

## データの保持期間

過去30日分のみを保持し、実行のたびに30日より古いデータは自動的に削除されます。

## ファイル構成

| パス | 役割 |
|---|---|
| `scripts/extract-channels.ps1` | チャンネルマスタ（`data/channels.json`）を生成するスクリプト |
| `scripts/fetch-epg.ps1` | J:COM APIから番組表データを取得・保存するメインスクリプト |
| `data/channels.json` | チャンネル一覧（siteId・地域・表示名など） |
| `data/state.json` | 次回実行時の処理開始位置（cursor） |
| `data/epg/` | 取得した番組表データの本体 |
| `.github/workflows/fetch-epg.yml` | 定期実行用のGitHub Actionsワークフロー |

## 手動実行

GitHub Actionsの「Actions」タブから `Fetch J:COM EPG` ワークフローを選び、「Run workflow」で手動実行できます（`gh workflow run fetch-epg.yml` でも可）。

※ 手動実行できるのは、このリポジトリへの書き込み権限（Write以上）を持つユーザーのみです。publicリポジトリのためコードは誰でも閲覧できますが、第三者が勝手に実行することはできません。
