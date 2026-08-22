Add-Type -AssemblyName System.Drawing

function Col($h) { [System.Drawing.ColorTranslator]::FromHtml($h) }
function Br($h) { New-Object System.Drawing.SolidBrush (Col $h) }
function Fnt($n, $s, $st = 'Regular') { New-Object System.Drawing.Font $n, $s, ([System.Drawing.FontStyle]$st) }

$teal = '#3ddc97'; $blue = '#4bc8ff'; $amber = '#e8c34a'; $pink = '#ff6ba6'
$grey = '#7d8f9c'; $dim = '#33424d'

function Budget($total, $parts, $rows, $sub1, $sub2, $note1, $note2, $used, $file) {
    $W = 1100; $H = 780
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.Clear((Col '#070b0e'))

    $sl = New-Object System.Drawing.Pen (Col '#0d1318'), 1
    for ($y = 0; $y -lt $H; $y += 3) { $g.DrawLine($sl, 0, $y, $W, $y) }

    $g.DrawString('F R E D G I S', (Fnt 'Consolas' 15 'Bold'), (Br $grey), 60, 44)
    $g.DrawString($total, (Fnt 'Consolas' 78 'Bold'), (Br $teal), 52, 66)
    $g.DrawString('BYTES', (Fnt 'Consolas' 30 'Bold'), (Br '#1f6e4d'), 372, 116)
    $g.DrawString($sub1, (Fnt 'Consolas' 13), (Br $grey), 58, 172)
    $g.DrawString($sub2, (Fnt 'Consolas' 13), (Br $dim), 58, 194)

    $g.DrawString('FILE LAYOUT', (Fnt 'Consolas' 14 'Bold'), (Br '#c8d6df'), 58, 244)
    $x0 = 58; $bw = 984; $by = 276; $bh = 54
    $sum = 0; foreach ($p in $parts) { $sum += $p.b }
    $x = $x0
    foreach ($p in $parts) {
        $w = [int]($bw * $p.b / $sum)
        $g.FillRectangle((Br $p.c), $x, $by, $w - 3, $bh)
        $g.DrawString($p.n, (Fnt 'Consolas' 12 'Bold'), (Br '#07110c'), $x + 10, $by + 8)
        $g.DrawString("$($p.b)", (Fnt 'Consolas' 15 'Bold'), (Br '#07110c'), $x + 10, $by + 26)
        $x += $w
    }
    $g.DrawString($note1, (Fnt 'Consolas' 12), (Br $grey), 58, 344)
    $g.DrawString($note2, (Fnt 'Consolas' 12), (Br $grey), 58, 364)

    $g.DrawString('WHAT IS INSIDE .TEXT', (Fnt 'Consolas' 14 'Bold'), (Br '#c8d6df'), 58, 408)
    $y = 440; $lab = 430; $barMax = 470
    $max = 0; foreach ($r in $rows) { if ($r.b -gt $max) { $max = $r.b } }
    foreach ($r in $rows) {
        $g.DrawString($r.n, (Fnt 'Consolas' 12), (Br '#aebdc7'), 58, $y)
        $w = [int]($barMax * $r.b / $max)
        $g.FillRectangle((Br $dim), $x0 + $lab, $y + 3, $barMax, 13)
        $g.FillRectangle((Br $r.c), $x0 + $lab, $y + 3, $w, 13)
        $g.DrawString("$($r.b)", (Fnt 'Consolas' 12 'Bold'), (Br $r.c), $x0 + $lab + $barMax + 12, $y)
        $y += 26
    }
    $g.DrawString($used, (Fnt 'Consolas' 12), (Br $grey), 58, 712)
    $g.Dispose()
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "wrote $file"
}

# ---------------------------------------------------------------- full build
Budget '5 632' `
    @(@{n='headers';b=512;c=$pink}, @{n='.text';b=4096;c=$teal}, @{n='.idata';b=1024;c=$blue}) `
    @(
        @{n='WndProc      frame loop and import thunks';      b=1132; c=$teal},
        @{n='DemoMain     window, layered DIB, GDI font';     b=499;  c=$blue},
        @{n='StartMusic   chiptune synthesis and waveOut';    b=455;  c=$pink},
        @{n='starfield    project, trail, respawn';           b=375;  c=$blue},
        @{n='AlphaPass    premultiplied compositor';          b=366;  c=$teal},
        @{n='MakeMask     plank silhouette and smoothstep';   b=355;  c=$pink},
        @{n='BurnEdges    the fire simulation';               b=344;  c=$teal},
        @{n='data         font, palette, tune, scroll text';  b=280;  c=$amber},
        @{n='logo + rain  block font rasteriser';             b=167;  c=$blue},
        @{n='entry + RNG';                                    b=43;   c=$grey}
    ) `
    'Windows x64 executable  .  pure NASM assembly  .  no runtime, no library, no asset' `
    'starfield  .  layered transparency  .  burning edges  .  scroller  .  8 bit chiptune' `
    'every section is rounded up to a 512 byte file alignment block, so the real' `
    'currency is blocks, not instructions: .text holds 4 016 bytes in its 4 096' `
    '21 imported symbols across four DLLs. The full demo.' `
    (Join-Path $PSScriptRoot 'bytes.png')

# ----------------------------------------------------------------- 4k build
Budget '4 096' `
    @(@{n='headers';b=512;c=$pink}, @{n='.text';b=3072;c=$teal}, @{n='.idata';b=512;c=$blue}) `
    @(
        @{n='DrawFrame    frame loop and import thunks';      b=841; c=$teal},
        @{n='starfield    project, trail, respawn';           b=375; c=$pink},
        @{n='AlphaPass    premultiplied compositor';          b=366; c=$blue},
        @{n='MakeMask     plank silhouette and smoothstep';   b=355; c=$teal},
        @{n='BurnEdges    the fire simulation';               b=344; c=$blue},
        @{n='DemoMain     window, layered DIB, message loop'; b=322; c=$pink},
        @{n='logo + rain  block font rasteriser';             b=167; c=$teal},
        @{n='data         font and palette only';             b=147; c=$amber},
        @{n='entry + RNG';                                    b=43;  c=$grey}
    ) `
    'the same demo with the music, the scroller and the drag removed' `
    'starfield  .  layered transparency  .  burning edges  .  Matrix rain' `
    'eight imports instead of twenty one, which is what gets .idata under 512.' `
    '.text holds 2 960 bytes in its 3 072: 112 bytes of headroom left' `
    'Eight imported symbols across three DLLs. No sound, no scrolling text.' `
    (Join-Path $PSScriptRoot 'bytes4k.png')
