# Builds FFXIPort release ZIPs with portable '/' entry names and a SHA-256 manifest.
# GPL-3.0-only, (C) 2026 wildthing.
#
# Usage (from the repository root):
#   powershell -File tools/build_release.ps1 -Name FFXIPort-1.1.0 -Profile install
#   powershell -File tools/build_release.ps1 -Name FFXIPort-1.1.0-source -Profile source
#
#   install : what players and server operators need: the Ashita addon, the
#             server module, README / INSTALL / CHANGELOG / NOTICE / LICENSE and
#             the provenance documents. No tests, tools or test output.
#   source  : the complete source distribution (client, server, docs, tests,
#             test results, tools, all top-level documents).
# Refuses to overwrite an existing ZIP or staging folder of the same name.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [ValidateSet('install', 'source')][string]$Profile = 'install'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root  = (Get-Location).Path
$out   = Join-Path $root 'release'
$zip   = Join-Path $out "$Name.zip"
$stage = Join-Path $out $Name
if (Test-Path $zip)   { throw "refusing to overwrite $zip" }
if (Test-Path $stage) { throw "refusing to overwrite $stage" }
New-Item -ItemType Directory -Force $stage | Out-Null

$topFiles = 'README.md', 'INSTALL.md', 'CHANGELOG.md', 'NOTICE.md', 'LICENSE'

if ($Profile -eq 'install') {
    Copy-Item -Recurse (Join-Path $root 'client') $stage
    New-Item -ItemType Directory -Force (Join-Path $stage 'server/modules/custom/late') | Out-Null
    Copy-Item (Join-Path $root 'server/modules/custom/late/fpxport.lua') (Join-Path $stage 'server/modules/custom/late/fpxport.lua')
    New-Item -ItemType Directory -Force (Join-Path $stage 'docs') | Out-Null
    foreach ($d in 'PROVENANCE-M8.md', 'CLEANROOM.md', 'CATALOGUE.md', 'SERVER-MODULE.md', 'PROTOCOL-FPX1.md') {
        Copy-Item (Join-Path $root "docs/$d") (Join-Path $stage "docs/$d")
    }
} else {
    foreach ($p in 'client', 'server', 'docs', 'tests', 'tools') { Copy-Item -Recurse (Join-Path $root $p) $stage }
}
foreach ($f in $topFiles) { Copy-Item (Join-Path $root $f) $stage }

# Never ship editor/OS leftovers.
Get-ChildItem -Recurse -Force -File $stage | Where-Object { $_.Name -match '(?i)^(thumbs\.db|desktop\.ini|\.ds_store)$|~$|\.(bak|tmp|swp|orig)$' } | Remove-Item -Force

function RelPath([string]$base, [string]$full) { $full.Substring($base.Length + 1).Replace('\', '/') }

# MANIFEST.sha256: "<sha256>  <path>", '/' separators, LF endings, ordinal order.
$sorted = [string[]](Get-ChildItem -Recurse -File $stage | ForEach-Object { RelPath $stage $_.FullName })
[Array]::Sort($sorted, [StringComparer]::Ordinal)
$lines = foreach ($r in $sorted) { '{0}  {1}' -f (Get-FileHash (Join-Path $stage $r) -Algorithm SHA256).Hash.ToLower(), $r }
[IO.File]::WriteAllText((Join-Path $stage 'MANIFEST.sha256'), (($lines -join "`n") + "`n"))

# ZIP: every entry is "<Name>/<relative/path>" with '/' separators.
$fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
$za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    $all = [string[]](Get-ChildItem -Recurse -File $stage | ForEach-Object { RelPath $stage $_.FullName })
    [Array]::Sort($all, [StringComparer]::Ordinal)
    foreach ($r in $all) {
        $entry = $za.CreateEntry("$Name/$r", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = (Get-Item (Join-Path $stage $r)).LastWriteTime
        $src = [IO.File]::OpenRead((Join-Path $stage $r))
        $dst = $entry.Open()
        try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
    }
} finally { $za.Dispose(); $fs.Dispose() }

$zh = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$zip.sha256", "$zh  $Name.zip`n")
"profile: $Profile"
"files: $($sorted.Count) (+ MANIFEST.sha256)"
"zip:   $zip"
"sha256 $zh"
