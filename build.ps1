# Build FREDGIS. Requires nasm and a mingw-w64 ld on PATH.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$ld = Get-Command ld -ErrorAction SilentlyContinue
if (-not $ld) { throw "mingw-w64 'ld' not found on PATH" }
$lib = Join-Path (Split-Path (Split-Path $ld.Source)) 'x86_64-w64-mingw32\lib'

nasm -Ox -f win64 fredgis.asm -o fredgis.o
if ($LASTEXITCODE) { throw 'nasm failed' }

ld -mi386pep --subsystem windows -e start -s -T tiny.ld -o fredgis.exe `
   fredgis.o "-L$lib" -lkernel32 -luser32 -lgdi32 -lwinmm
if ($LASTEXITCODE) { throw 'ld failed' }

Remove-Item fredgis.o -ErrorAction SilentlyContinue
"fredgis.exe  $((Get-Item fredgis.exe).Length) bytes"
