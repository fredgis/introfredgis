# Build FREDGIS. Requires nasm and a mingw-w64 ld on PATH.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$ld = Get-Command ld -ErrorAction SilentlyContinue
if (-not $ld) { throw "mingw-w64 'ld' not found on PATH" }
$lib = Join-Path (Split-Path (Split-Path $ld.Source)) 'x86_64-w64-mingw32\lib'

function Build($src, $out, $libs) {
    nasm -Ox -f win64 $src -o build.o
    if ($LASTEXITCODE) { throw "nasm failed on $src" }
    ld -mi386pep --subsystem windows -e start -s -T tiny.ld -o $out build.o "-L$lib" @libs
    if ($LASTEXITCODE) { throw "ld failed on $src" }
    & "$PSScriptRoot\pecompact.ps1" -Path "$PSScriptRoot\$out" | Out-Null
    Remove-Item build.o -ErrorAction SilentlyContinue
    "{0,-16} {1} bytes" -f $out, (Get-Item $out).Length
}

Build 'fredgis.asm'   'fredgis.exe'   @('-lkernel32','-luser32','-lgdi32','-lwinmm')
Build 'fredgis4k.asm' 'fredgis4k.exe' @('-lkernel32','-luser32','-lgdi32')
