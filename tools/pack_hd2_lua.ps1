[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $LuaFile,
    [Parameter(Mandatory = $true)] [string] $TemplatePatch,
    [Parameter(Mandatory = $true)] [string] $OutputDirectory,
    [Parameter(Mandatory = $false)] [string] $ZipFile
)

$ErrorActionPreference = 'Stop'

function Set-U32LE([byte[]] $Data, [int] $Offset, [int] $Value) {
    $v = [uint32]$Value
    $Data[$Offset + 0] = [byte]($v -band 0xFF)
    $Data[$Offset + 1] = [byte](($v -shr 8) -band 0xFF)
    $Data[$Offset + 2] = [byte](($v -shr 16) -band 0xFF)
    $Data[$Offset + 3] = [byte](($v -shr 24) -band 0xFF)
}

$luaPath = [IO.Path]::GetFullPath($LuaFile)
$templatePath = [IO.Path]::GetFullPath($TemplatePatch)
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $luaPath -PathType Leaf)) { throw "Lua file not found: $luaPath" }
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Template patch not found: $templatePath" }

$lua = [IO.File]::ReadAllBytes($luaPath)
$template = [IO.File]::ReadAllBytes($templatePath)
$marker = [Text.Encoding]::ASCII.GetBytes('-- HD2-Addon:')
$offset = -1
for ($i = 0; $i -le $template.Length - $marker.Length; $i++) {
    $ok = $true
    for ($j = 0; $j -lt $marker.Length; $j++) {
        if ($template[$i + $j] -ne $marker[$j]) { $ok = $false; break }
    }
    if ($ok) { $offset = $i; break }
}
if ($offset -lt 0) { throw 'Template does not contain an embedded HD2 Lua marker.' }

$tail = 0
for ($i = $template.Length - 1; $i -ge $offset -and $template[$i] -eq 0; $i--) { $tail++ }
$prefix = $template[0..($offset - 1)]
$suffix = if ($tail -gt 0) { $template[($template.Length - $tail)..($template.Length - 1)] } else { [byte[]]@() }
$newLength = $prefix.Length + $lua.Length + $suffix.Length
$packed = [byte[]]::new($newLength)
[Array]::Copy($prefix, 0, $packed, 0, $prefix.Length)
[Array]::Copy($lua, 0, $packed, $prefix.Length, $lua.Length)
[Array]::Copy($suffix, 0, $packed, $prefix.Length + $lua.Length, $suffix.Length)

# HD2 patch container length fields observed in this package format.
Set-U32LE $packed 0x20 $newLength
Set-U32LE $packed 0xA0 ($lua.Length + 8)
Set-U32LE $packed 0xC0 $lua.Length

if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $outDir 'Addon') -Force | Out-Null
$outPatch = Join-Path $outDir ('Addon\' + [IO.Path]::GetFileName($templatePath))
[IO.File]::WriteAllBytes($outPatch, $packed)

foreach ($name in @('9ba626afa44a3aa3.patch_0.gpu_resources', '9ba626afa44a3aa3.patch_0.stream')) {
    $source = Join-Path ([IO.Path]::GetDirectoryName($templatePath)) $name
    [IO.File]::WriteAllBytes((Join-Path $outDir ('Addon\' + $name)), [IO.File]::ReadAllBytes($source))
}
$manifest = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($templatePath))) 'manifest.json'
if (Test-Path -LiteralPath $manifest) {
    $manifestText = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8)
    $manifestText = $manifestText -replace '"Guid":\s*"[^"]+"', '"Guid": "b1f7d2a4-6e39-4c80-9a15-7d2f4e8b603c"'
    $manifestText = $manifestText -replace '"Name":\s*"Turret Free Cooldown"', '"Name": "New Turret Modification"'
    [IO.File]::WriteAllText((Join-Path $outDir 'manifest.json'), $manifestText, [Text.UTF8Encoding]::new($false))
}

if (-not [string]::IsNullOrWhiteSpace($ZipFile)) {
    $zipPath = [IO.Path]::GetFullPath($ZipFile)
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -LiteralPath (Join-Path $outDir '*') -DestinationPath $zipPath -Force
    Write-Host "ZIP: $zipPath"
}
Write-Host "Packed patch: $outPatch ($newLength bytes; Lua payload $($lua.Length) bytes)"
