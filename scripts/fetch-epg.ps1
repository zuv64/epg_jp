# J:COM公開番組表APIからEPGデータを取得し、地域ごとのフォルダに複製保存するスクリプト。
#
# 出力構造（方式1: 実データを地域ごとに複製保存）:
#   data/epg/<地域名>/<siteId>/<yyyyMMdd>.json
#
# 331チャンネル × 7日分 = 2317タスクを一度に全部取得すると時間がかかりすぎるため、
# data/state.json の cursor で「前回どこまで処理したか」を管理し、1回の実行では
# BatchSize 件だけ処理して cursor を進める（一周すると先頭に戻る）。
#
# API仕様（com.reclink.app.network.EpgClient を参照）:
#   - URL: https://tvguide.myjcom.jp/api/getEpgInfo/?channels=<siteId>_<yyyyMMdd>&rectime=&rec4k=
#   - 認証不要。User-Agent / Referer ヘッダーのみ必要
#   - 複数チャンネル・複数日をまとめて1リクエストにすると502エラーになるため、
#     必ず「チャンネル1件 x 日付1日」で1リクエストとすること

param(
    [int]$BatchSize = 580,
    [int]$IntervalSeconds = 10,
    # 保存期間（日数）。この日数より古い yyyyMMdd.json は毎回の実行時に自動削除する
    [int]$RetentionDays = 30
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$channelsPath = Join-Path $root "data\channels.json"
$statePath = Join-Path $root "data\state.json"
$epgDir = Join-Path $root "data\epg"

$USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
$REFERER = "https://tvguide.myjcom.jp/"
$BASE_URL = "https://tvguide.myjcom.jp/api/getEpgInfo/"

$channels = Get-Content -Raw -Encoding UTF8 $channelsPath | ConvertFrom-Json

# JST（UTC+9、日本にサマータイムはないため単純加算でよい）の「今日」を基準に、今日から7日分の日付リストを作る
$jstNow = ([DateTime]::UtcNow).AddHours(9)
$today = $jstNow.Date
$dates = 0..6 | ForEach-Object { $today.AddDays($_).ToString("yyyyMMdd") }

# タスクリスト（siteId昇順 x 日付昇順）を生成。1タスク=1チャンネルx1日で、
# regionsに複数地域が入っていれば、取得結果をその全地域フォルダに複製保存する。
$tasks = New-Object System.Collections.Generic.List[object]
foreach ($ch in ($channels | Sort-Object siteId)) {
    foreach ($d in $dates) {
        $tasks.Add([PSCustomObject]@{
            siteId  = $ch.siteId
            date    = $d
            regions = $ch.regions
        })
    }
}
Write-Output "Total tasks: $($tasks.Count)"

# state.json（cursor管理）を読み込む。無ければ先頭から開始
$state = if (Test-Path $statePath) {
    Get-Content -Raw -Encoding UTF8 $statePath | ConvertFrom-Json
} else {
    [PSCustomObject]@{ cursor = 0 }
}
$cursor = [int]$state.cursor
if ($tasks.Count -eq 0) {
    Write-Output "No tasks. Exiting."
    exit 0
}
if ($cursor -ge $tasks.Count) { $cursor = 0 }

# cursorからBatchSize件を切り出す（末尾に達したら先頭に戻ってループ）
$batch = New-Object System.Collections.Generic.List[object]
$idx = $cursor
for ($i = 0; $i -lt $BatchSize -and $i -lt $tasks.Count; $i++) {
    $batch.Add($tasks[$idx])
    $idx++
    if ($idx -ge $tasks.Count) { $idx = 0 }
}
$nextCursor = $idx
Write-Output "Processing batch: $($batch.Count) tasks (cursor $cursor -> $nextCursor)"

$headers = @{
    "User-Agent" = $USER_AGENT
    "Referer"    = $REFERER
}

$successCount = 0
$failCount = 0

foreach ($task in $batch) {
    $key = "$($task.siteId)_$($task.date)"
    $url = "$BASE_URL`?channels=$key&rectime=&rec4k="
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 15
        $prop = $resp.PSObject.Properties[$key]
        $programs = if ($prop) { $prop.Value } else { @() }

        # パイプ経由(`@($programs) | ConvertTo-Json`)だと空配列のとき何も流れず0バイトになるため、
        # -InputObject で明示的に渡す
        $jsonText = ConvertTo-Json -InputObject @($programs) -Depth 10
        foreach ($region in $task.regions) {
            $outDir = Join-Path $epgDir "$region\$($task.siteId)"
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $outFile = Join-Path $outDir "$($task.date).json"
            $jsonText | Out-File -FilePath $outFile -Encoding utf8
        }
        $successCount++
    } catch {
        Write-Warning "Failed: $key - $($_.Exception.Message)"
        $failCount++
    }
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Output "Success: $successCount, Failed: $failCount"

# state.jsonを更新
[PSCustomObject]@{
    cursor    = $nextCursor
    lastRunAt = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json | Out-File -FilePath $statePath -Encoding utf8

# 保存期間（既定30日）を過ぎた過去データを削除する
$cutoff = $today.AddDays(-$RetentionDays)
if (Test-Path $epgDir) {
    $oldFiles = Get-ChildItem -Path $epgDir -Recurse -File -Filter "*.json" | Where-Object {
        $parsed = [DateTime]::MinValue
        [DateTime]::TryParseExact($_.BaseName, "yyyyMMdd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsed) -and $parsed -lt $cutoff
    }
    if ($oldFiles.Count -gt 0) {
        Write-Output "Deleting $($oldFiles.Count) files older than $RetentionDays days (before $($cutoff.ToString('yyyyMMdd')))"
        $oldFiles | Remove-Item -Force
    }

    # 削除の結果空になったディレクトリも掃除する（siteIdフォルダ・地域フォルダの順で深い方から）
    Get-ChildItem -Path $epgDir -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { (Get-ChildItem -Path $_.FullName -Force | Measure-Object).Count -eq 0 } |
        Remove-Item -Force
}

Write-Output "State updated: cursor=$nextCursor"
