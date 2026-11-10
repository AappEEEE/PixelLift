# 用 GitHub Git Data API 提交本地 HEAD（github.com:443 被重置时走 443 的 api 通道）
# 关键点：文件内容用 base64 传输、提交信息按 UTF-8 原始字节解码，避免 PowerShell 5.1 的编码破坏。

$ErrorActionPreference = "Stop"
$repo = "AappEEEE/PixelLift"
$branch = "main"
$tmpDir = Join-Path $env:TEMP "ghpush"
New-Item -ItemType Directory -Force $tmpDir | Out-Null

function Write-Utf8Json($obj, $name) {
    $p = Join-Path $tmpDir $name
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText($p, $json, [Text.UTF8Encoding]::new($false))
    return $p
}

function Get-RawBytes($gitPath) {
    # 工作区与 HEAD 一致时，直接读文件字节（避免任何文本编码介入）
    $full = Join-Path (Get-Location) ($gitPath -replace "/", "\")
    if (Test-Path $full) { return [IO.File]::ReadAllBytes($full) }
    throw "文件不存在: $gitPath"
}

Write-Host "== 远端 head =="
$ref = gh api "repos/$repo/git/ref/heads/$branch" | Out-String | ConvertFrom-Json
$baseCommit = $ref.object.sha
$baseTree = (gh api "repos/$repo/git/commits/$baseCommit" | Out-String | ConvertFrom-Json).tree.sha
Write-Host "base=$baseCommit baseTree=$baseTree"

$localTree = (git rev-parse "HEAD^{tree}").Trim()
Write-Host "localTree=$localTree"

# 提交信息：临时把控制台输出编码切成 UTF-8，避免 5.1 默认 GBK 解码破坏中文
$prevEnc = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$message = ((git log -1 --pretty=%B) -join "`n").TrimEnd("`r", "`n")
[Console]::OutputEncoding = $prevEnc
Write-Host "message=<$($message.Split("`n")[0])>"

$files = @(git -c core.quotepath=false diff-tree --no-commit-id --name-only -r HEAD)
Write-Host "changed files ($($files.Count)): $($files -join ', ')"

$entries = @()
foreach ($f in $files) {
    $b64 = [Convert]::ToBase64String((Get-RawBytes $f))
    $body = Write-Utf8Json @{ content = $b64; encoding = "base64" } "blob.json"
    $sha = (gh api --method POST "repos/$repo/git/blobs" --input $body | Out-String | ConvertFrom-Json).sha
    $local = (git rev-parse "HEAD:$f").Trim()
    $mark = if ($sha -eq $local) { "OK" } else { "MISMATCH($local)" }
    Write-Host ("  {0,-32} {1} {2}" -f $f, $sha, $mark)
    $entries += @{ path = $f; mode = "100644"; type = "blob"; sha = $sha }
}

$treeBody = Write-Utf8Json @{ base_tree = $baseTree; tree = $entries } "tree.json"
$newTree = (gh api --method POST "repos/$repo/git/trees" --input $treeBody | Out-String | ConvertFrom-Json).sha
Write-Host "newTree=$newTree  match=$($newTree -eq $localTree)"

$commitBody = Write-Utf8Json @{ message = $message; tree = $newTree; parents = @($baseCommit) } "commit.json"
$newCommit = gh api --method POST "repos/$repo/git/commits" --input $commitBody | Out-String | ConvertFrom-Json
Write-Host "newCommit=$($newCommit.sha)"
Write-Host "author=$($newCommit.author.name) <$($newCommit.author.email)> $($newCommit.author.date)"
Write-Host "committer=$($newCommit.committer.name) <$($newCommit.committer.email)> $($newCommit.committer.date)"

$refBody = Write-Utf8Json @{ sha = $newCommit.sha; force = $false } "ref.json"
$null = gh api --method PATCH "repos/$repo/git/refs/heads/$branch" --input $refBody | Out-String
Write-Host "== 远端 $branch 已更新 =="

# 本地重建同一个 commit 对象，让本地与远端 sha 一致
$authorTs = [DateTimeOffset]::Parse($newCommit.author.date).ToUnixTimeSeconds()
$committerTs = [DateTimeOffset]::Parse($newCommit.committer.date).ToUnixTimeSeconds()
$msgLf = $message -replace "`r`n", "`n"
$tzOf = { param($d) $o = ([DateTimeOffset]::Parse($d)).Offset; $sign = if ($o.TotalMinutes -lt 0) { "-" } else { "+" }; $h = [math]::Abs([int]$o.TotalHours); $m = [math]::Abs($o.Minutes); "{0}{1:d2}{2:d2}" -f $sign, $h, $m }
$raw = "tree $newTree`nparent $baseCommit`nauthor $($newCommit.author.name) <$($newCommit.author.email)> $authorTs $(& $tzOf $newCommit.author.date)`ncommitter $($newCommit.committer.name) <$($newCommit.committer.email)> $committerTs $(& $tzOf $newCommit.committer.date)`n`n$msgLf`n"
$rawFile = Join-Path $tmpDir "commit-raw.txt"
[IO.File]::WriteAllText($rawFile, $raw, [Text.UTF8Encoding]::new($false))
$crafted = (git hash-object -t commit -w --path . "$rawFile") | Out-String
$crafted = $crafted.Trim()
Write-Host "crafted=$crafted"
if ($crafted -eq $newCommit.sha) {
    git update-ref "refs/heads/$branch" $crafted
    Write-Host "本地与远端已对齐"
} else {
    Write-Host "哈希不一致（内容相同、元数据不同）：远端已更新，本地稍后 git fetch 同步即可"
}
git log --oneline -2
