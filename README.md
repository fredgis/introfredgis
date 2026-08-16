# FREDGIS

A 1990s style cracktro for Windows x64, written in **pure NASM assembly**.
No C, no CRT, no framework, no external asset: **6 144 bytes** on disk, three
system DLLs, one source file.

![FREDGIS](docs/fredgis.gif)

The window is not a rectangle. It is a stack of horizontal planks whose torn
ends burn away into grey ash and green blue embers, and the whole thing is
slightly see-through, so the desktop stays faintly visible behind it. Every
pixel — the letters, the fire, the stars, the transparency — is rasterised by
hand into a memory bitmap.

---

## Contents

| File | Purpose |
| --- | --- |
| `fredgis.asm` | The whole demo. ~1 300 lines of NASM, 23 imported symbols. |
| `tiny.ld` | Custom linker script that strips the sections mingw emits for a C runtime we do not have. |
| `build.ps1` | One command build. |
| `docs/` | Screenshots and the animated capture. |

## Build

You need [NASM](https://www.nasm.us/) and the `ld` from a **mingw-w64**
toolchain, both on `PATH`.

```powershell
.\build.ps1
```

Or by hand:

```powershell
$lib = Join-Path (Split-Path (Split-Path (Get-Command ld).Source)) "x86_64-w64-mingw32\lib"
nasm -Ox -f win64 fredgis.asm -o fredgis.o
ld -mi386pep --subsystem windows -e start -s -T tiny.ld -o fredgis.exe `
   fredgis.o "-L$lib" -lkernel32 -luser32 -lgdi32
```

`ld` is used only as a PE writer and import table generator. Nothing from
libgcc, libmsvcrt or the mingw startup files is linked in: `start` is the raw
entry point and the process ends with `ExitProcess`.

## Run

```powershell
.\fredgis.exe
```

* **Drag anywhere** to move the window — there is no title bar.
* **Escape** to quit.

Every launch is different: the plank silhouette, the starfield and the fire are
all seeded from `GetTickCount`.

![screenshot](docs/demo.png)

---

# How it works

## 1. The window is a bitmap, not a window

An irregular outline with *soft* edges cannot be done with a region —
`SetWindowRgn` is 1-bit, so it can only cut hard shapes. So the demo is a
`WS_EX_LAYERED` window that is never painted by `WM_PAINT`. Instead we own a
32 bpp DIB and hand it to the compositor whole:

```nasm
    call BurnEdges
    call AlphaPass

    mov rcx, qword [rsp + 80]           ; hand the surface to the compositor
    xor edx, edx
    xor r8d, r8d
    lea r9, [ulw_size]
    mov rax, qword [rsp + 88]
    mov qword [rsp + 32], rax
    lea rax, [ulw_src]
    mov qword [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea rax, [ulw_blend]
    mov qword [rsp + 56], rax
    mov qword [rsp + 64], ULW_ALPHA
    call UpdateLayeredWindow
```

The surface comes from `CreateDIBSection` with a **negative height**, which
makes it top-down, so the memory is a plain `B,G,R,A` array and a dword reads
naturally as `0x00RRGGBB`.

There is no double buffering, no `BitBlt` and no device context involved in
presenting: `UpdateLayeredWindow` *is* the swap.

## 2. `AlphaPass` — the compositor

This is the heart of the demo, and the two rules that govern it are easy to get
wrong:

**GDI never writes the alpha byte.** Anything `TextOutA` touches comes back with
`A = 0`. So `AlphaPass` runs last and is the sole owner of the alpha channel —
and it must run *after* `GdiFlush`, because GDI batches its calls and would
otherwise stomp on pixels we already composited.

**Alpha must be premultiplied.** `UpdateLayeredWindow` with `ULW_ALPHA` expects
`channel = channel * a >> 8`:

```nasm
    mov edx, dword [r14 + rcx * 4]      ; premultiply the three channels
    movzx r8d, dl
    imul r8d, eax
    shr r8d, 8
    shr edx, 8
    movzx r9d, dl
    imul r9d, eax
    shr r9d, 8
    shr edx, 8
    movzx edx, dl
    imul edx, eax
    shr edx, 8
    shl edx, 16
    shl r9d, 8
    or edx, r9d
    or edx, r8d
    shl r10d, 24                        ; alpha keeps the untouched coverage
    or edx, r10d
    mov dword [r14 + rcx * 4], edx
```

Nothing in the demo ever reaches alpha 255. The coverage tops out at
`GLOBAL_A = 226`, which is what makes the whole window slightly transparent:

```nasm
%define GLOBAL_A            226          ; nothing is fully solid: the desktop
                                         ; stays faintly visible through it all
```

## 3. `MakeMask` — the plank silhouette

Six planks of 45 rows. Each one picks how deep it tears on the left and on the
right, independently, so no two ends line up. The fade width is floored,
because a very long tip would otherwise leave no room for a gradient at all:

```nasm
    call NextRand
    and eax, 15
    imul eax, eax, 7                    ; 12..117: the planks must end at very
    add eax, 12                         ; different depths or the silhouette
    mov r14d, eax                       ; reads as a plain rectangle again
    mov ecx, PLANK_CORE
    sub ecx, eax
    cmp ecx, 40                         ; a long tip would leave no room for
    jge .fade_l                         ; the ramp, so give it a floor
    mov ecx, 40
.fade_l:
    mov dword [rsp + 32], ecx           ; left fade width
```

The ramp itself is **squared**. A linear ramp gives a mathematically smooth but
visually straight edge — you still read a rectangle. Squaring it keeps the
alpha low across most of the tip, so the ragged fire, not the gradient, is what
your eye follows:

```nasm
    shl eax, 8                          ; t = d/fade in 0..256
    cdq
    idiv dword [rsp + 32]
    imul eax, eax                       ; square it: the ramp stays low across
    shr eax, 8                          ; most of the tip so the ragged fire,
    imul eax, GLOBAL_A                  ; not a straight gradient, draws the
    shr eax, 8                          ; silhouette there
```

## 4. `BurnEdges` — the fire

A Doom style fire rotated 90°, anchored to each plank's own tip rather than to
a fixed column, propagating outwards. The inner loop runs 2 × 270 × 96 times
per frame, so the RNG is inlined rather than called:

```nasm
    imul r15d, r15d, 1103515245         ; inline LCG, no call in these loops
    add r15d, 12345
```

Each row has its own heat that random-walks every frame. The bias matters more
than it looks:

```nasm
    and eax, 127
    sub eax, 63                         ; near unbiased walk: without this the
                                        ; rows all pin to 255 and the fire turns
                                        ; into a flat band instead of tongues
```

But an independent walk per row is *vertically uncorrelated*, which renders as
fine static. Diffusing the heat along y a little every frame builds up the
correlation that turns static into tongues of different lengths:

```nasm
    mov r9d, 2
.smooth_pass:
    movzx r8d, byte [r10]               ; previous row, clamped at the top
    xor r12d, r12d
.smooth:
    movzx eax, byte [r10 + r12]
    lea edx, [r12 + 1]
    cmp edx, SCR_H
    jb .sm_next
    mov edx, r12d
.sm_next:
    movzx edx, byte [r10 + rdx]
    add edx, r8d
    lea edx, [rdx + rax * 2]
    shr edx, 2
    mov r8d, eax                        ; the neighbour must stay unsmoothed
    mov byte [r10 + r12], dl
```

Propagation outwards cools each step by a random amount. The mask is small
(`0..7`) so a hot tongue carries most of the 96 pixel width before dying:

```nasm
    movzx r8d, byte [r14 + rdx - 1]     ; heat of the column one step in
    shr eax, 6
    and eax, 7                          ; slow cooling, so the tongues carry far
    sub r8d, eax
    jns .cool_ok
    xor r8d, r8d
```

![burning edges](docs/edges.png)

### Ash and embers from one number

The fire is a single 0..255 heat value, but it has to look like two things at
once: **charcoal smoke** where the plank frays, melting into **green blue
embers** where it burns. That is just a colour ramp where red dies out as the
heat rises:

```nasm
    mov edx, 255                        ; the cold tail reads as ash: R ~ G ~ B
    sub edx, eax                        ; so the tips end in grey black smoke
    imul edx, eax                       ; that melts into the green blue core
    shr edx, 8
    shl edx, 16
    lea r8d, [rax + rax * 2]            ; B = 3f/4
    shr r8d, 2
    or edx, r8d
    mov r8d, eax                        ; G = f
    shl r8d, 8
    or edx, r8d
```

| heat | R | G | B | reads as |
| --- | --- | --- | --- | --- |
| 30 | 26 | 30 | 22 | dark grey ash |
| 80 | 54 | 80 | 60 | grey green |
| 180 | 52 | 180 | 135 | ember |
| 255 | 0 | 255 | 191 | bright green blue |

Compositing is a single SSE instruction — a saturating byte add across all four
channels at once — and the coverage becomes `max(mask, heat)`, so embers glow
slightly past the tear and the silhouette itself ends in flame:

```nasm
    movd xmm0, dword [r14 + rcx * 4]    ; saturating add over all channels
    movd xmm1, edx
    paddusb xmm0, xmm1
    movd dword [r14 + rcx * 4], xmm0
```

## 5. The block font

`FREDGIS` is not drawn with a typeface. It is seven bytes-per-row glyphs stored
in the source and scaled ×7 straight into the DIB:

```nasm
; Block font, 8x8 per letter, most significant bit on the left. Only the seven
; letters of the name are stored.
glyph_data:
    db 0xFE, 0xC0, 0xC0, 0xFC, 0xC0, 0xC0, 0xC0, 0xC0   ; F
    db 0xFC, 0xC6, 0xC6, 0xFC, 0xD8, 0xCC, 0xC6, 0xC3   ; R
    db 0xFE, 0xC0, 0xC0, 0xFC, 0xC0, 0xC0, 0xC0, 0xFE   ; E
    db 0xFC, 0xC6, 0xC3, 0xC3, 0xC3, 0xC3, 0xC6, 0xFC   ; D
    db 0x3E, 0x60, 0xC0, 0xC0, 0xCF, 0xC3, 0x63, 0x3E   ; G
    db 0xFE, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0xFE   ; I
    db 0x7E, 0xC3, 0xC0, 0x7C, 0x06, 0x03, 0xC3, 0x7E   ; S
```

`BuildLogo` transposes that into `colbits`, one dword per logo column, so the
Matrix rain can ask "is there a block at column `x`, row `y`?" with a single
`bt`.

## 6. Matrix rain inside the letters

The drops only light up blocks that belong to a letter — the rain lives
*inside* the logo, it never renders outside it. Drop heads are tracked in 1/64
of a block row so they can fall at fractional speeds, and the trail is four
palette entries deep:

```nasm
    lea rax, [rain_y]
    mov eax, dword [rax + r12 * 4]
    sar eax, 6                          ; head, in block rows
    sub eax, r13d
    js .rain_next
    cmp eax, GLYPH_ROWS
    jae .rain_next
    lea rcx, [colbits]
    mov ecx, dword [rcx + r12 * 4]
    bt ecx, eax                         ; is there a block here at all?
    jnc .rain_next
```

```nasm
; Rain palette, 0x00RRGGBB: bright head then a fading tail.
level_col     dd 0x00D8FFE8, 0x0044FF88, 0x0022E068, 0x001AC055
```

![logo](docs/logo.png)

## 7. Starfield, scroller, scanlines

200 stars are projected from a vanishing point with a `STAR_FOV` focal length,
each drawing a radial trail from its previous screen position. The trails are
plotted by a hand written DDA (`DrawTrail`) straight into the bitmap, which
removed four GDI imports.

The scrolling message is the one thing GDI still draws for us, with `TextOutA`.
Every odd row is then scaled to `205/255` for the worn CRT feel — **colour
only, never alpha**, or half the window would go see-through.

---

# Frame order

```
inline clear  →  TextOutA (scroller)  →  GdiFlush  →  DrawTrail (stars)
   →  logo + Matrix rain + glitch blocks  →  BurnEdges  →  AlphaPass
   →  UpdateLayeredWindow
```

A `SetTimer` at 20 ms drives it. CPU cost is around 0.05–0.25 s for a five
second run.

# Routines

| Routine | Role |
| --- | --- |
| `start` | Entry point, seeds the RNG, calls `DemoMain`, `ExitProcess`. |
| `NextRand` | 32-bit xorshift. Everything random comes from here. |
| `MakeMask` | Per-row alpha mask of the planks; records each tip so the fire knows where to burn. |
| `BuildLogo` / `DrawBlock` | Block font rasteriser, Matrix rain and glitch blocks. |
| `InitField` / `ResetStar` / `ProjectStar` / `SyncTrail` | Starfield simulation and perspective projection. |
| `DrawTrail` | DDA line plotter, replaces `MoveToEx` / `LineTo`. |
| `BurnEdges` | Sideways fire simulation at the plank tips. |
| `AlphaPass` | Scanlines, fire compositing, alpha and premultiply. |
| `DemoMain` | Window class, layered window, DIB, message loop. |
| `WndProc` | 20 ms timer tick, drag to move, Escape to quit. |

---

# Size

The demo is **6 144 bytes**. Getting there was mostly a fight with the PE
layout rather than with the code.

A PE file is `SizeOfHeaders` plus every section rounded up to the 512 byte file
alignment, so the real currency is *sections*, not instructions:

```
headers   0x400
.text     0xff0  →  0x1000        (4080 of 4096 used)
.idata    0x3f4  →  0x0400        (1012 of 1024 used)
                    ------
                    0x1800  =  6144
```

Both sections sit within a few bytes of a 512 byte cliff, so the budget is real:
adding one import or one more line of scroll text costs 512 bytes of file.

What worked:

* **`tiny.ld`.** The default mingw script emits `.rdata` constructor markers,
  `.edata`, `.tls`, `.didat` and pseudo-reloc sections that a freestanding
  program has no use for. Discarding them dropped 7 168 → 6 656 bytes.
* **Fewer imports.** 28 symbols down to 23. `BitBlt` became an inline qword
  clear loop; `GetStockObject`, `SetDCPenColor`, `MoveToEx` and `LineTo` were
  replaced by `DrawTrail`.
* **Code diet.** Runs of `mov qword [rsp+N], 0` before the big API calls became
  `rep stosq`; the constant `SIZE`, `POINT` and `BLENDFUNCTION` structures moved
  out of the stack frame into `.text` literals; the scroll text was trimmed to
  fit the remaining bytes.

What did not work, and is worth knowing:

* **`--file-alignment 16 --section-alignment 16`** produces a 2 KB file that the
  **x64 loader refuses to run**. On x64, `SectionAlignment` must be ≥ 0x1000.
* **Merging `.idata` into `.text`** gives 2 sections and 5 632 bytes, but
  Windows Defender **deletes the binary on sight**: a single loaded section with
  the import table inside executable code is a textbook packer signature. Not
  worth 512 bytes.
* **Merging `.bss` into `.data`** turns the uninitialised arrays into raw file
  contents. The executable went from 6 KB to **206 KB**.

---

# Notes for the curious

A few things that cost real debugging time:

* `.bss` arrays cannot be addressed as `[label + reg*4]`. NASM emits a 32-bit
  absolute relocation and `ld` fails with *relocation truncated to fit*. Always
  `lea` the base into a register first — hence the `lea rax, [rain_y]` that
  precedes every table access in this source.
* Random masks must be `2^n − 1`. A non power of two `and` silently ruins the
  distribution; the starfield collapsed into a cross before this was fixed.
* At function entry on x64, `rsp ≡ 8 (mod 16)`; a `push rbp` restores alignment.
  Getting this wrong crashes deep inside GDI, far from the actual mistake.
* Scaling *alpha* instead of *colour* in the scanline pass makes every odd row
  translucent and the whole window looks washed out. This class of bug is
  invisible in the source and obvious in a screenshot — most of the visual work
  here was done by looking at captures, not at code.

# License

Do whatever you want with it.
