[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $InputFile,

    [Parameter(Mandatory = $false, Position = 1)]
    [string] $OutputFile
)

$ErrorActionPreference = 'Stop'

$inputPath = [IO.Path]::GetFullPath($InputFile)
if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Input file not found: $inputPath"
}

$bytes = [IO.File]::ReadAllBytes($inputPath)
$marker = [Text.Encoding]::ASCII.GetBytes('-- HD2-Addon:')
$offset = -1

for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
    $match = $true
    for ($j = 0; $j -lt $marker.Length; $j++) {
        if ($bytes[$i + $j] -ne $marker[$j]) {
            $match = $false
            break
        }
    }
    if ($match) {
        $offset = $i
        break
    }
}

if ($offset -lt 0) {
    throw "No embedded HD2 Lua marker found in: $inputPath"
}

$end = $bytes.Length
while ($end -gt $offset -and $bytes[$end - 1] -eq 0) {
    $end--
}

$lua = [Text.Encoding]::UTF8.GetString($bytes, $offset, $end - $offset)
if ([string]::IsNullOrWhiteSpace($lua)) {
    throw "Embedded Lua payload is empty: $inputPath"
}

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = [IO.Path]::Combine(
        [IO.Path]::GetDirectoryName($inputPath),
        ([IO.Path]::GetFileNameWithoutExtension($inputPath) + '.lua')
    )
}

$outputPath = [IO.Path]::GetFullPath($OutputFile)
$parent = [IO.Path]::GetDirectoryName($outputPath)
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
}

[IO.File]::WriteAllText($outputPath, $lua, [Text.UTF8Encoding]::new($false))

Write-Host ("Extracted {0} bytes from offset 0x{1:X}; removed {2} trailing NUL byte(s)." -f ($end - $offset), $offset, ($bytes.Length - $end))
Write-Host "Lua file: $outputPath"
