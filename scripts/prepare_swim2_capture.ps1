param(
    [Parameter(Mandatory = $true)][string]$Rbf,
    [Parameter(Mandatory = $true)][string]$Main,
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'

$sources = [ordered]@{}
foreach ($entry in @(@('rbf', $Rbf), @('main', $Main), @('image', $Image))) {
    $source = Get-Item -LiteralPath $entry[1]
    if ($source -isnot [IO.FileInfo] -or $source.Length -eq 0) {
        throw "Expected a nonempty file: $($entry[1])"
    }
    $sources[$entry[0]] = $source
}

$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $outputPath) {
    throw "Capture directory already exists: $outputPath"
}
$null = New-Item -ItemType Directory -Path $outputPath
$names = @{
    rbf = 'MacLC475.rbf'
    main = 'MiSTer'
    image = "floppy$($sources.image.Extension)"
}
$artifacts = [ordered]@{}
foreach ($role in $sources.Keys) {
    $source = $sources[$role]
    $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $destination = Join-Path $outputPath $names[$role]
    Copy-Item -LiteralPath $source.FullName -Destination $destination
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
        throw "Copy verification failed: $destination; discard this incomplete capture directory."
    }
    $artifacts[$role] = [ordered]@{
        file = $names[$role]
        source = $source.FullName
        sha256 = $hash
        bytes = (Get-Item -LiteralPath $destination).Length
    }
}
(Get-Item -LiteralPath (Join-Path $outputPath $names.image)).IsReadOnly = $false
$manifest = [ordered]@{
    created_utc = [DateTime]::UtcNow.ToString('o')
    artifacts = $artifacts
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputPath 'manifest.json') -Encoding UTF8
@'
RBF source revision and trace fit/timing result:
Main source revision and patches:
Confirm the bundled RBF and Main were loaded:
Guest OS and exact actions, including mount, eject, remount and reset:
Observed failure and first failing action:
Saved image path and SHA-256 after eject and host I/O completion:
'@ | Set-Content -LiteralPath (Join-Path $outputPath 'steps.txt') -Encoding ASCII
Write-Output "Prepared capture: $outputPath"
Write-Output "Use the bundled RBF/Main and mount only $($names.image). Record actions in steps.txt."
Write-Output 'Start UART capture before mounting. Preserve manifest.json and the original input image.'
