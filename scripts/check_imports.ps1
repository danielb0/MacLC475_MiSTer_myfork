$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$imports = Get-Content (Join-Path $root 'docs/imports.json') -Raw | ConvertFrom-Json
$checked = 0
foreach ($entry in $imports) {
    $path = Join-Path $root $entry.destination
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing import: $($entry.destination)"
    }
    if ($entry.adapted) { continue }
    $content = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '').ToLower()
    } finally {
        $sha.Dispose()
    }
    if ($hash -ne $entry.sha256_lf) {
        throw "Changed pinned import: $($entry.destination)"
    }
    $checked++
}
Write-Output "Verified $checked preserved imports; $($imports.Count) imported files present."
