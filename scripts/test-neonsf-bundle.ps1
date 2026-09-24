param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDirectory
)

$ErrorActionPreference = 'Stop'

$resolvedBundle = (Resolve-Path -LiteralPath $BundleDirectory).Path
$executable = Join-Path $resolvedBundle 'HanabiNeoNSF.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "NeoNSF executable is missing: $executable"
}

$probeText = & $executable --probe
if ($LASTEXITCODE -ne 0) {
    throw "NeoNSF probe exited with code $LASTEXITCODE"
}

try {
    $probe = $probeText | ConvertFrom-Json
} catch {
    throw "NeoNSF probe returned invalid JSON: $probeText"
}

if ($probe.name -ne 'NeoNSF' -or
    [int]$probe.protocolVersion -ne 2 -or
    $probe.ready -ne $true) {
    throw "Unsupported NeoNSF probe response: $probeText"
}

Write-Host "NeoNSF $($probe.version), protocol $($probe.protocolVersion), ready"
