$srcPath = "c:\dev\android\srec\android\app\src\main\java\com\reclink\app\network\EpgModels.kt"
$content = Get-Content -Raw -Encoding UTF8 $srcPath
$channelPattern = 'EpgChannel\((\d+),\s*(\d+),\s*(\d+),\s*"([^"]*)",\s*"([^"]*)",\s*(\d+)\)'

# KANTO_KEY_STATIONS（withKantoKeyStations()で各地域に合成される共通の関東キー局データ）を抽出
$kantoDefMatch = [regex]::Match($content, 'KANTO_KEY_STATIONS[\s\S]*?listOf\(([\s\S]*?)\n    \)\r?\n')
$kantoChannels = [regex]::Matches($kantoDefMatch.Groups[1].Value, $channelPattern) | ForEach-Object {
    [PSCustomObject]@{
        channelType = [int]$_.Groups[1].Value
        channelId   = [int]$_.Groups[2].Value
        networkId   = [int]$_.Groups[3].Value
        displayName = $_.Groups[4].Value
    }
}
Write-Output "KANTO_KEY_STATIONS count: $($kantoChannels.Count)"

# 地域ブロック（"地域名" to listOf(... または "地域名" to withKantoKeyStations("地域名", listOf(...)）の
# 開始位置を列挙し、次のブロック開始位置までをその地域のテキスト範囲として扱う
$blockPattern = '"(?<region>[^"]+)"\s*to\s*(?<kanto>withKantoKeyStations\("[^"]+",\s*)?listOf\('
$blockMatches = [regex]::Matches($content, $blockPattern)
Write-Output "Region block count: $($blockMatches.Count)"

$rows = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $blockMatches.Count; $i++) {
    $bm = $blockMatches[$i]
    $startIdx = $bm.Index + $bm.Length
    $endIdx = if ($i + 1 -lt $blockMatches.Count) { $blockMatches[$i + 1].Index } else { $content.Length }
    $blockText = $content.Substring($startIdx, $endIdx - $startIdx)
    $regionName = $bm.Groups['region'].Value
    $isKanto = $bm.Groups['kanto'].Success

    $blockChannelMatches = [regex]::Matches($blockText, $channelPattern)
    foreach ($m in $blockChannelMatches) {
        $region = $m.Groups[5].Value
        if ($region -eq "") { $region = $regionName }
        $rows.Add([PSCustomObject]@{
            siteId        = "$($m.Groups[1].Value)_$($m.Groups[2].Value)_$($m.Groups[3].Value)"
            channelType   = [int]$m.Groups[1].Value
            channelId     = [int]$m.Groups[2].Value
            networkId     = [int]$m.Groups[3].Value
            displayName   = $m.Groups[4].Value
            region        = $region
            remoconNumber = [int]$m.Groups[6].Value
        })
    }

    if ($isKanto) {
        $baseCount = $blockChannelMatches.Count
        for ($k = 0; $k -lt $kantoChannels.Count; $k++) {
            $kc = $kantoChannels[$k]
            $rows.Add([PSCustomObject]@{
                siteId        = "$($kc.channelType)_$($kc.channelId)_$($kc.networkId)"
                channelType   = $kc.channelType
                channelId     = $kc.channelId
                networkId     = $kc.networkId
                displayName   = $kc.displayName
                region        = $regionName
                remoconNumber = $baseCount + $k + 1
            })
        }
    }
}

Write-Output "Total rows: $($rows.Count)"

# siteId単位でユニーク化し、regionsを配列としてまとめる
$grouped = $rows | Group-Object siteId
$channels = foreach ($g in $grouped) {
    $first = $g.Group[0]
    $regions = $g.Group | Select-Object -ExpandProperty region -Unique
    [PSCustomObject]@{
        siteId        = $first.siteId
        channelType   = $first.channelType
        channelId     = $first.channelId
        networkId     = $first.networkId
        displayName   = $first.displayName
        remoconNumber = $first.remoconNumber
        regions       = @($regions)
    }
}

Write-Output "Unique channel count: $($channels.Count)"

$outDir = "c:\dev\epg\data"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$channels | Sort-Object siteId | ConvertTo-Json -Depth 5 | Out-File -FilePath "$outDir\channels.json" -Encoding utf8
Write-Output "Written: $outDir\channels.json"

