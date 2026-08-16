# Compact the PE headers in place.
#
# ld pads SizeOfHeaders out to 0x400 even though the DOS stub, the COFF and
# optional headers and the three section headers all fit in 0x200. That is a
# whole 512 byte file alignment block of nothing. Shrink SizeOfHeaders to
# 0x200, pull every section's PointerToRawData down by the same amount and
# drop the padding.
param([string]$Path)

$b = [IO.File]::ReadAllBytes($Path)
$pe = [BitConverter]::ToInt32($b, 0x3C)
$optSize = [BitConverter]::ToUInt16($b, $pe + 20)
$nSect = [BitConverter]::ToUInt16($b, $pe + 6)
$opt = $pe + 24
$sect = $opt + $optSize

$headersEnd = $sect + 40 * $nSect
$old = [BitConverter]::ToInt32($b, $opt + 60)
$new = [int]([Math]::Ceiling($headersEnd / 512) * 512)
if ($new -ge $old) { "headers already tight ($old)"; exit 0 }
$delta = $old - $new

[Array]::Copy([BitConverter]::GetBytes([int]$new), 0, $b, $opt + 60, 4)
for ($i = 0; $i -lt $nSect; $i++) {
    $p = $sect + 40 * $i + 20
    $raw = [BitConverter]::ToInt32($b, $p)
    if ($raw -ne 0) {
        [Array]::Copy([BitConverter]::GetBytes([int]($raw - $delta)), 0, $b, $p, 4)
    }
}

$out = New-Object byte[] ($b.Length - $delta)
[Array]::Copy($b, 0, $out, 0, $new)
[Array]::Copy($b, $old, $out, $new, $b.Length - $old)
[IO.File]::WriteAllBytes($Path, $out)
"headers 0x{0:X} -> 0x{1:X}, saved {2} bytes" -f $old, $new, $delta
