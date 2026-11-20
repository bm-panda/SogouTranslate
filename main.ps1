param(
    [Parameter(Position = 0)]
    [string]$paramPath
)

$ErrorActionPreference = 'Stop'
$MaxTextLength = 1000
$HomeUrl = 'https://fanyi.sogou.com/'
$TranslateUrl = 'https://fanyi.sogou.com/text?keyword={0}&transfrom=auto&transto=zh-CHS&model=general'

function Send-Bubble {
    param(
        [string]$ApiBase,
        [ValidateSet('success', 'error', 'info')]
        [string]$NotifyType,
        [string]$Message,
        [int]$Duration = 5000
    )
    if ([string]::IsNullOrWhiteSpace($ApiBase)) { return }
    try {
        $body = @{ notify_type = $NotifyType; message = $Message; duration = $Duration } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$($ApiBase.TrimEnd('/'))/api/notify" -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 5 | Out-Null
    } catch {
        Write-Output (@{ status = 'notify_failed'; detail = $_.Exception.Message } | ConvertTo-Json -Compress)
    }
}

# data 的每个键恒为数组；这里兼容数组 / 单值 / 缺失三种形态
function Get-DataText {
    param($Data, [string]$Name)
    if (-not $Data) { return '' }
    $prop = $Data.PSObject.Properties[$Name]
    if (-not $prop) { return '' }
    $value = $prop.Value
    if ($null -eq $value) { return '' }
    if ($value -is [string]) { return $value }
    foreach ($item in @($value)) {
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) { return [string]$item }
    }
    return ''
}

function Open-Url {
    param([string]$Url)
    try {
        Start-Process -FilePath $Url
        return $null
    } catch {
        # 回落到 Process.Start 再试一次
    }
    try {
        [System.Diagnostics.Process]::Start($Url) | Out-Null
        return $null
    } catch {
        return $_.Exception.Message
    }
}

if ([string]::IsNullOrWhiteSpace($paramPath) -and $args.Count -gt 0) {
    $paramPath = [string]$args[0]
}

# 没传参数文件、文件读不出来时也照常打开首页，不中断
$environment = $null
$data = @{}
$warning = $null

if (-not [string]::IsNullOrWhiteSpace($paramPath)) {
    try {
        $payload = Get-Content -LiteralPath $paramPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $environment = $payload.environment
        if ($payload.data) { $data = $payload.data }
    } catch {
        $warning = "参数文件读取失败，已改为打开翻译首页: $($_.Exception.Message)"
    }
}

$apiBase = if ($environment -and $environment.api_base) { [string]$environment.api_base } else { '' }
$keyword = (Get-DataText -Data $data -Name 'target_text').Trim()

$url = $HomeUrl
$truncated = $false
$mode = 'home'

if ($keyword.Length -gt 0) {
    # 超长文本会让 URL 超出浏览器上限，截断并告知用户；截断点落在代理对中间时回退一位
    if ($keyword.Length -gt $MaxTextLength) {
        $cut = $MaxTextLength
        if ([char]::IsHighSurrogate($keyword[$cut - 1])) { $cut-- }
        $keyword = $keyword.Substring(0, $cut)
        $truncated = $true
        Send-Bubble -ApiBase $apiBase -NotifyType 'info' -Message "文本较长，仅翻译前 $MaxTextLength 个字符" -Duration 3000
    }
    $url = $TranslateUrl -f [uri]::EscapeDataString($keyword)
    $mode = 'translate'
}

$openError = Open-Url -Url $url

if ($openError) {
    Send-Bubble -ApiBase $apiBase -NotifyType 'error' -Message "打开浏览器失败: $openError" -Duration 3000
    Write-Output (@{ status = 'error'; error = "打开浏览器失败: $openError" } | ConvertTo-Json -Compress)
    exit 1
}

$result = @{ status = 'ok'; mode = $mode; url = $url; truncated = $truncated }
if ($keyword.Length -gt 0) { $result.keyword = $keyword }
if ($warning) { $result.warning = $warning }
Write-Output ($result | ConvertTo-Json -Compress)
exit 0
