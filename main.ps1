param(
    [Parameter(Position = 0)]
    [string]$paramPath
)

$ErrorActionPreference = 'Stop'
$MaxTextLength = 1000

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

if ([string]::IsNullOrWhiteSpace($paramPath) -and $args.Count -gt 0) {
    $paramPath = [string]$args[0]
}

if ([string]::IsNullOrWhiteSpace($paramPath)) {
    Write-Output (@{ status = 'error'; error = '缺少参数文件路径' } | ConvertTo-Json -Compress)
    exit 1
}

try {
    $payload = Get-Content -LiteralPath $paramPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Output (@{ status = 'error'; error = "无法解析参数文件: $($_.Exception.Message)" } | ConvertTo-Json -Compress)
    exit 1
}

$environment = $payload.environment
$data = if ($payload.data) { $payload.data } else { @{} }
$apiBase = if ($environment -and $environment.api_base) { [string]$environment.api_base } else { '' }

$keyword = (Get-DataText -Data $data -Name 'target_text').Trim()

if ($keyword.Length -eq 0) {
    Send-Bubble -ApiBase $apiBase -NotifyType 'info' -Message '没有取到要翻译的文本：请先复制内容再双击 Ctrl+C，或在盒子搜索框粘贴文本' -Duration 3000
    Write-Output (@{ status = 'info'; message = '翻译内容为空' } | ConvertTo-Json -Compress)
    exit 0
}

# 超长文本会让 URL 超出浏览器上限，截断并告知用户
$truncated = $false
if ($keyword.Length -gt $MaxTextLength) {
    # 截断点落在代理对中间会得到非法字符，回退一位
    $cut = $MaxTextLength
    if ([char]::IsHighSurrogate($keyword[$cut - 1])) { $cut-- }
    $keyword = $keyword.Substring(0, $cut)
    $truncated = $true
    Send-Bubble -ApiBase $apiBase -NotifyType 'info' -Message "文本较长，仅翻译前 $MaxTextLength 个字符" -Duration 3000
}

$encodedKeyword = [uri]::EscapeDataString($keyword)
$url = "https://fanyi.sogou.com/text?keyword=$encodedKeyword&transfrom=auto&transto=zh-CHS&model=general"

$opened = $false
$lastError = $null

try {
    Start-Process -FilePath $url
    $opened = $true
} catch {
    $lastError = $_.Exception.Message
}

if (-not $opened) {
    try {
        [System.Diagnostics.Process]::Start($url) | Out-Null
        $opened = $true
        $lastError = $null
    } catch {
        $lastError = $_.Exception.Message
    }
}

if (-not $opened) {
    Send-Bubble -ApiBase $apiBase -NotifyType 'error' -Message "打开浏览器失败: $lastError" -Duration 3000
    Write-Output (@{ status = 'error'; error = "打开浏览器失败: $lastError" } | ConvertTo-Json -Compress)
    exit 1
}

Write-Output (@{ status = 'ok'; keyword = $keyword; url = $url; truncated = $truncated } | ConvertTo-Json -Compress)
exit 0
