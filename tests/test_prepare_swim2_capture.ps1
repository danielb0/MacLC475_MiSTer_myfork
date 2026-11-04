$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $root "local/tests/capture-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $fixture -Force
$inputs = @{
    Rbf = Join-Path $fixture 'trace.rbf'
    Main = Join-Path $fixture 'MiSTer'
    Image = Join-Path $fixture "clean $([char]0xe9).img"
}
[IO.File]::WriteAllBytes($inputs.Rbf, [byte[]](1, 2, 3))
[IO.File]::WriteAllBytes($inputs.Main, [byte[]](4, 5, 6))
[IO.File]::WriteAllBytes($inputs.Image, [byte[]](0, 127, 128, 255))
(Get-Item -LiteralPath $inputs.Image).IsReadOnly = $true
$prepare = Join-Path $root 'scripts/prepare_swim2_capture.ps1'
$output = Join-Path $fixture 'capture with spaces'
& $prepare @inputs -OutputDirectory $output
$manifest = Get-Content -LiteralPath (Join-Path $output 'manifest.json') -Raw | ConvertFrom-Json
foreach ($role in @('rbf', 'main', 'image')) {
    $artifact = $manifest.artifacts.$role
    $source = Get-Item -LiteralPath $inputs[$role]
    $copy = Get-Item -LiteralPath (Join-Path $output $artifact.file)
    $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($artifact.source -ne $source.FullName -or $artifact.sha256 -ne $hash -or
        $artifact.bytes -ne $source.Length -or $copy.Length -ne $source.Length -or
        (Get-FileHash -LiteralPath $copy.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
        throw "Capture provenance mismatch: $role"
    }
}
if (!(Get-Item -LiteralPath $inputs.Image).IsReadOnly -or
    (Get-Item -LiteralPath (Join-Path $output $manifest.artifacts.image.file)).IsReadOnly) {
    throw 'Only the disposable image must be writable'
}
$hashes = Get-ChildItem -LiteralPath $output -File | Get-FileHash -Algorithm SHA256
$rejected = $false
try { & $prepare @inputs -OutputDirectory $output } catch { $rejected = $true }
if (!$rejected) { throw 'Existing capture directory was accepted' }
foreach ($file in $hashes) {
    if ((Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ne $file.Hash) {
        throw 'Existing capture was altered'
    }
}
foreach ($name in @('missing', 'empty')) {
    $invalid = $inputs.Clone()
    $invalid.Image = Join-Path $fixture "$name.img"
    if ($name -eq 'empty') { [IO.File]::WriteAllBytes($invalid.Image, [byte[]]@()) }
    $invalidOutput = Join-Path $fixture $name
    $rejected = $false
    try { & $prepare @invalid -OutputDirectory $invalidOutput } catch { $rejected = $true }
    if (!$rejected -or (Test-Path -LiteralPath $invalidOutput)) {
        throw "Invalid input created a capture directory: $name"
    }
}
Write-Output 'PASS: capture hashes, copies, writable media, Unicode paths, overwrite refusal and invalid inputs'
