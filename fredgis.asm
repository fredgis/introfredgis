; ============================================================================
; FREDGIS - Win64 cracktro, 100 % NASM, no C, no CRT
; ----------------------------------------------------------------------------
;   - the window is a stack of horizontal PLANKS whose left and right ends
;     dissolve into real transparency; that needs per-pixel alpha, so the demo
;     is a layered window fed by UpdateLayeredWindow from a 32 bpp DIB we own
;   - worn CRT look: every other line is darkened for the scanline feel
;   - the torn ends of the planks smoulder: a sideways Doom fire pushes grey
;     ash and green blue embers outwards so the silhouette ends in flame
;     instead of a straight edge
;   - the whole window is slightly see-through, coverage tops out at GLOBAL_A
;   - the FREDGIS logo uses a hand made block font stored in this file, so no
;     system typeface is involved; letters are painted straight into the DIB
;   - MATRIX rain runs down the letters: drops light up the blocks they cross
;   - detached glitch blocks flicker around the word
;   - perspective starfield with radial trails, scrolling message
;
; Build (PowerShell). tiny.ld drops the sections mingw emits for a C runtime
; we do not have, which is worth a kilobyte in the final image:
;   $lib = Join-Path (Split-Path (Split-Path (Get-Command ld).Source)) `
;          "x86_64-w64-mingw32\lib"
;   nasm -Ox -f win64 fredgis.asm -o fredgis.o
;   ld -mi386pep --subsystem windows -e start -s -T tiny.ld -o fredgis.exe `
;      fredgis.o "-L$lib" -lkernel32 -luser32 -lgdi32 -lwinmm
; ============================================================================

bits 64
default rel

%define WS_POPUP_VISIBLE    0x90000000   ; WS_POPUP | WS_VISIBLE
%define WS_EX_LAYERED       0x00080000
%define ULW_ALPHA           2
%define BLEND_ARGB          0x01FF0000   ; AC_SRC_OVER, 255, AC_SRC_ALPHA
%define WM_DESTROY          0x0002
%define WM_KEYDOWN          0x0100
%define WM_TIMER            0x0113
%define WM_LBUTTONDOWN      0x0201
%define WM_NCLBUTTONDOWN    0x00A1
%define HTCAPTION           2
%define VK_ESCAPE           27
%define TIMER_MS            20
%define TRANSPARENT         1

%define SCR_W               720
%define SCR_H               270
%define CX                  360          ; starfield vanishing point
%define CY                  124

%define NPLANK              6            ; NPLANK * PLANK_H must equal SCR_H
%define PLANK_H             45
%define PLANK_FADE          64           ; power of two: the ramp divide is a
                                         ; shift instead of an idiv
%define TIP_MAX             50           ; deepest a plank end can be eaten,
                                         ; wobble included
%define PLANK_CORE          (TIP_MAX + PLANK_FADE)
%define GLOBAL_A            196          ; nothing is fully solid: the desktop
                                         ; stays clearly visible through it all
%define FIRE_W              176          ; how far a flame can reach past the tip
%define FLAME_IN            72           ; the source sits inside the solid core,
                                         ; so the fire covers the whole ramp and
                                         ; there is no bare gradient to see
%define FLAME_RISE          64           ; power of two. The fire is faded in
%define FLAME_RISE_LOG      6            ; over this many pixels: at full heat
                                         ; from the first column it would draw a
                                         ; straight black to green seam right
                                         ; where the source sits
%define SCANLINE            205          ; colour scale of every odd row

%define SND_HZ              8000         ; crunchy on purpose: this is the
                                         ; sample rate a 1990s intro would use
%define SND_ROWS            128          ; two parts of eight seconds: the riff,
                                         ; then the same thing an octave down
%define SND_ROWLEN          1000         ; 125 ms, so the loop is eight seconds
%define AUDIO_LEN           (SND_ROWS * SND_ROWLEN)

%define STARS               200

; Stars and rain drops are interleaved records walked with a pointer, not
; parallel arrays indexed by a counter. Every field then reaches through a
; small displacement instead of a seven byte lea of an absolute label, which
; is where most of the code size in these loops used to go.
%define ST_X                0
%define ST_Y                4
%define ST_Z                8
%define ST_SX               12
%define ST_SY               16
%define ST_PX               20
%define ST_PY               24
%define ST_N                8            ; 32 bytes, so the walk is add rbx, 32
%define RN_Y                0
%define RN_V                4
%define RN_N                2
%define STAR_NEAR           26
%define STAR_SPEED          5
%define STAR_SPREAD         512          ; power of two: contiguous AND mask
%define STAR_FOV            192          ; focal length of the projection
%define STAR_FAT            130          ; below this z a star gets thicker

%define GLYPH_ROWS          8            ; block font geometry
%define GLYPH_PITCH         9            ; 8 columns of pixels plus one gap
%define LOGO_COLS           62           ; 7 letters, trailing gap dropped
%define SCALE               7            ; pixels per block
%define LOGO_W              (LOGO_COLS * SCALE)
%define LOGO_H              (GLYPH_ROWS * SCALE)
%define RAIN_TRAIL          6
%define GLITCH              14

%define SCROLL_H            20
%define SCROLL_CW           13           ; Lucida Console is fixed pitch, so the
                                         ; scroller width is a constant and does
                                         ; not need GetTextExtentPoint32A
%define SCROLL_Y            (SCR_H - 46)
%define SCROLL_SPEED        2

extern ExitProcess
extern RegisterClassA
extern CreateWindowExA
extern UpdateLayeredWindow
extern ReleaseCapture
extern SendMessageA
extern GetMessageA
extern DispatchMessageA
extern DefWindowProcA
extern SetTimer
extern CreateFontA
extern SelectObject
extern SetBkMode
extern SetTextColor
extern TextOutA
extern CreateCompatibleDC
extern CreateDIBSection
extern GdiFlush
extern waveOutOpen
extern waveOutPrepareHeader
extern waveOutWrite

; ----------------------------------------------------------------------------
; Constants live inside .text: no extra section, hence no extra PE padding.
; ----------------------------------------------------------------------------
section .text

class_name    db "F", 0
scroll_font   db "Lucida Console", 0

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

; Rain palette, 0x00RRGGBB: bright head then a fading tail.
level_col     dd 0x00D8FFE8, 0x0044FF88, 0x0022E068, 0x001AC055
              dd 0x0012A044, 0x000C8034

scroll_text   db "CONVICTION & DATA: THE FUEL OF THE MODERN ARCHITECT    ", 0
scroll_len    equ $ - scroll_text - 1

ulw_size      dd SCR_W, SCR_H             ; constant arguments of the blit
ulw_blend     dd BLEND_ARGB
              dd 0, 0                     ; POINT {0, 0}

dib_head      dd 40                       ; BITMAPINFOHEADER, a pure constant:
              dd SCR_W                    ; built here rather than on the stack
              dd -SCR_H                   ; negative height: top down rows
              dw 1, 32                    ; biPlanes, biBitCount, BI_RGB
              dd 0

; One octave of phase increments for the 8 kHz oscillators: incr = f * 65536
; / SND_HZ, starting at C2. Any higher octave is the same value shifted left,
; which is why notes are packed as (octave << 4) | semitone.
note_incr     dw 536, 568, 601, 637, 675, 715, 758, 803, 851, 901, 955, 1011

; The tune: Am - F - C - G, two seconds each, four arpeggio notes per chord.
arp_tab       db 0x39, 0x40, 0x44, 0x49
              db 0x35, 0x39, 0x40, 0x45
              db 0x30, 0x34, 0x37, 0x40
              db 0x37, 0x3B, 0x42, 0x47
bass_tab      db 0x19, 0x15, 0x10, 0x17

; Octave offsets per part. Nothing goes up: at 8 kHz the Nyquist limit is
; 4 kHz, and a pulse wave whose harmonics fold back around it turns to noise,
; so the second half drops an octave instead of climbing one.
part_octave   db 0, -16

wave_fmt      dw 1, 1                     ; WAVE_FORMAT_PCM, mono
              dd SND_HZ, SND_HZ           ; one byte per sample, so the byte
              dw 1, 8                     ; rate is the sample rate
              dw 0

section .bss
window_handle resq 1
mem_dc        resq 1
pixels        resq 1                      ; DIB bits, top down, 32 bpp
rng_seed      resd 1
frame_counter resd 1
x_pos         resd 1
y_pos         resd 1
x_vel         resd 1
y_vel         resd 1
scroll_x      resd 1
mask          resb SCR_W * SCR_H          ; static plank silhouette, 0..255
tip_l         resd SCR_H                  ; first and last lit column of a row
tip_r         resd SCR_H
fire          resb 2 * SCR_H * FIRE_W     ; edge flames, left band then right
src_heat      resb 2 * SCR_H              ; drifting heat feeding the flames
colbits       resd LOGO_COLS              ; one bit per block row of the logo
rain          resd LOGO_COLS * RN_N       ; drop head in 1/64 of a block row,
                                          ; then its speed
stars         resd STARS * ST_N           ; x, y, z, screen x/y, previous x/y
wave_out      resq 1
wave_hdr      resb 48                     ; WAVEHDR, x64 layout
audio         resb AUDIO_LEN              ; the whole tune, rendered once

section .text
global start
global WndProc

; ----------------------------------------------------------------------------
; Linear congruential generator -> eax
; ----------------------------------------------------------------------------
NextRand:
    mov eax, dword [rng_seed]
    imul eax, eax, 1664525
    add eax, 1013904223
    mov dword [rng_seed], eax
    shr eax, 11                         ; the low bits of an LCG are far too
    ret                                 ; regular, so throw them away

; ----------------------------------------------------------------------------
; Fill a SCALE by SCALE block straight into the DIB.
; ecx = x, edx = y, r8d = 0x00RRGGBB. Clobbers rax and rdx only.
; ----------------------------------------------------------------------------
DrawBlock:
    imul ecx, ecx, SCALE                ; block coordinates, scaled and offset
    add ecx, dword [x_pos]              ; here rather than at the three call
    imul edx, edx, SCALE                ; sites that used to do it themselves
    add edx, dword [y_pos]
    imul eax, edx, SCR_W
    add eax, ecx
    shl eax, 2
    push rdi
    mov rdi, qword [pixels]             ; a row is SCALE contiguous dwords, so
    add rdi, rax                        ; it is one rep stosd. That leaves rdi
    mov eax, r8d                        ; on the pixel after the block, and the
    push SCALE                          ; step to the next row is only the rest
    pop rdx                             ; of the scanline
.row:
    push SCALE
    pop rcx
    rep stosd
    add rdi, (SCR_W - SCALE) * 4
    dec edx
    jnz .row
    pop rdi
    ret

; ----------------------------------------------------------------------------
; Expand the block font into one row bitmask per logo column, then build the
; mask, scatter the stars and render the chiptune in one continuous pipeline.
; ----------------------------------------------------------------------------
BuildLogo:
    push rdi
    lea r8, [glyph_data]
    lea r9, [colbits]
    mov rdi, r9
    xor eax, eax
    push LOGO_COLS
    pop rcx
    rep stosd

    push 7
    pop r10                             ; 7 letters
.letter:
    xor r11d, r11d                      ; block row
.row:
    movzx ecx, byte [r8]
    inc r8
    xor edx, edx                        ; bit, 0 = leftmost
.bit:
    shl cl, 1
    jnc .next_bit
    bts dword [r9 + rdx * 4], r11d
.next_bit:
    inc edx
    cmp edx, 8
    jb .bit
    inc r11d
    cmp r11d, GLYPH_ROWS
    jb .row
    add r9, GLYPH_PITCH * 4
    dec r10d
    jnz .letter
    pop rdi
    ret

; ----------------------------------------------------------------------------
; The star rbx points at respawns far away.
; ----------------------------------------------------------------------------
ResetStar:
    push 2
    pop rcx
.xy:
    call NextRand
    and eax, (STAR_SPREAD * 2 - 1)
    sub eax, STAR_SPREAD
    mov dword [rbx + rcx * 4 - 4], eax
    dec ecx
    jnz .xy
    call NextRand
    movzx eax, al
    add eax, 384
    mov dword [rbx + ST_Z], eax
    ret

; ----------------------------------------------------------------------------
; Perspective projection of the star rbx points at.
; ----------------------------------------------------------------------------
ProjectStar:
    imul eax, dword [rbx + ST_X], STAR_FOV
    cdq
    idiv dword [rbx + ST_Z]
    add eax, CX
    mov dword [rbx + ST_SX], eax
    imul eax, dword [rbx + ST_Y], STAR_FOV
    cdq
    idiv dword [rbx + ST_Z]
    add eax, CY
    mov dword [rbx + ST_SY], eax
    ret

; ----------------------------------------------------------------------------
; Freeze the current position as the tail of the trail.
; ----------------------------------------------------------------------------
SyncTrail:
    mov rax, qword [rbx + ST_SX]
    mov qword [rbx + ST_PX], rax
    ret

; ----------------------------------------------------------------------------
; Scatter the stars and prime the rain columns.
; ----------------------------------------------------------------------------
InitField:
    push r12
    push rbx

    lea rbx, [stars]
    mov r12d, STARS
.stars:
    call ResetStar
    call NextRand                       ; spread the depths out
    and eax, 511
    add eax, STAR_NEAR + 8
    mov dword [rbx + ST_Z], eax
    call ProjectStar
    call SyncTrail
    add rbx, ST_N * 4
    dec r12d
    jnz .stars

    lea rbx, [rain]
    push LOGO_COLS
    pop r12
.rain:
    call NextRand
    and eax, 1023
    mov dword [rbx + RN_Y], eax
    call NextRand
    and eax, 15
    add eax, 3
    mov dword [rbx + RN_V], eax
    add rbx, RN_N * 4
    dec r12d
    jnz .rain

    pop rbx
    pop r12
    ret

; ----------------------------------------------------------------------------
; Build the static plank silhouette once.
; ----------------------------------------------------------------------------
MakeMask:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rsi
    push rdi

    lea r13, [mask]
    mov r10, r13
    lea rsi, [tip_l]
    lea rdi, [tip_r]
    xor r12d, r12d
    xor ebx, ebx
.plank:
    call NextRand
    and eax, 15
    lea eax, [rax * 2 + 16]             ; 16..TIP_MAX. The spread stays small:
    mov r14d, eax                       ; visible staircase of black steps

    call NextRand
    and eax, 15
    lea eax, [rax * 2 + 16]
    mov r15d, SCR_W
    sub r15d, eax                       ; where it stops on the right

    push PLANK_H
    pop r11
.tip:
    call NextRand
    and eax, 7                          ; wobble each row a few pixels: a tip
    sub eax, 4                           ; that is constant down the plank
    add eax, r14d                       ; draws a ruler straight edge, and a
    mov dword [rsi + rbx * 4], eax      ; straight edge is what reads as square
    call NextRand
    and eax, 7
    sub eax, 5
    add eax, r15d
    mov dword [rdi + rbx * 4], eax
    inc rbx
    dec r11d
    jnz .tip

    sub rbx, PLANK_H                    ; rewind: the row loop walks it again
    push PLANK_H
    pop r11
.row:
    mov r14d, dword [rsi + rbx * 4]     ; this row has its own pair of tips
    mov r15d, dword [rdi + rbx * 4]
    inc rbx
    xor ecx, ecx
.col:
    mov eax, ecx                        ; ramp up from the left tip
    sub eax, r14d
    test eax, eax
    jle .clear
    cmp eax, PLANK_FADE
    jge .left_full
    shl eax, 2                          ; t = d/PLANK_FADE in 0..256, a shift
    call SmoothStep                     ; because the width is a power of two
    jmp .have_left
.left_full:
    mov eax, GLOBAL_A
.have_left:
    mov r8d, eax
    mov eax, r15d                       ; ramp up from the right tip
    sub eax, ecx
    test eax, eax
    jle .clear
    cmp eax, PLANK_FADE
    jge .take_left
    shl eax, 2
    call SmoothStep
    cmp eax, r8d                        ; keep whichever end is dimmer
    jle .store
.take_left:
    mov eax, r8d
    jmp .store
.clear:
    xor eax, eax
.store:
    mov byte [r10 + rcx], al
    inc ecx
    cmp ecx, SCR_W
    jb .col
    add r10, SCR_W
    dec r11d
    jnz .row

    inc r12d
    cmp r12d, NPLANK
    jb .plank

    pop rdi
    pop rsi
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ----------------------------------------------------------------------------
; Smoothstep, 3t^2 - 2t^3, in fixed point.

; ----------------------------------------------------------------------------
; Smoothstep, 3t^2 - 2t^3, in fixed point.
;
; eax = t in 0..256, returns the curve scaled to 0..GLOBAL_A. A linear ramp is
; mathematically smooth but reads as a straight edge, and a plain square is
; worse: its slope is steepest where it meets the solid core, which is exactly
; the hard line we are trying to get rid of. Smoothstep is flat at both ends,
; so the plank melts into the fire with no visible seam. Only called while the
; mask is built, so the call in the inner loop costs nothing at runtime.
; ----------------------------------------------------------------------------
SmoothStep:
    mov edx, eax
    imul eax, eax
    shr eax, 8                          ; s = t^2 / 256
    imul edx, eax                       ; s * t
    shr edx, 7                          ; 2 * s * t / 256
    lea eax, [rax + rax * 2]            ; 3s
    sub eax, edx
    imul eax, GLOBAL_A
    shr eax, 8
    ret

; ----------------------------------------------------------------------------
; Plot one star trail straight into the DIB.
;
; ecx = head x, edx = head y, r8d = tail x, r9d = tail y, eax = colour.
; A plain DDA in 16.16 fixed point; a trail is only a few pixels long, so the
; step count is max(|dx|, |dy|) + 1 and both ends are lit. Points that fall
; outside the frame are dropped, which is all the clipping this needs.
; ----------------------------------------------------------------------------
DrawTrail:
    push rbx
    push rsi
    push rdi
    mov ebx, eax                        ; colour
    mov esi, ecx                        ; x in 16.16
    shl esi, 16
    mov edi, edx                        ; y in 16.16
    shl edi, 16
    mov r10d, r8d                       ; dx
    sub r10d, ecx
    mov r11d, r9d                       ; dy
    sub r11d, edx

    mov eax, r10d                       ; steps = max(|dx|, |dy|)
    test eax, eax
    jns .abs_dx
    neg eax
.abs_dx:
    mov ecx, r11d
    test ecx, ecx
    jns .abs_dy
    neg ecx
.abs_dy:
    cmp ecx, eax
    cmovg eax, ecx
    mov r9d, eax
    test r9d, r9d
    jz .plot                            ; head and tail on the same pixel
    mov eax, r10d                       ; per step increments
    shl eax, 16
    cdq
    idiv r9d
    mov r10d, eax
    mov eax, r11d
    shl eax, 16
    cdq
    idiv r9d
    mov r11d, eax
.plot:
    inc r9d
    mov r8, qword [pixels]
.step:
    mov eax, esi
    sar eax, 16
    cmp eax, SCR_W                      ; unsigned: also catches negatives
    jae .skip
    mov ecx, edi
    sar ecx, 16
    cmp ecx, SCR_H
    jae .skip
    imul ecx, ecx, SCR_W
    add ecx, eax
    mov dword [r8 + rcx * 4], ebx
.skip:
    add esi, r10d
    add edi, r11d
    dec r9d
    jnz .step
    pop rdi
    pop rsi
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Green blue flames licking the torn ends of the planks.
;
; A Doom fire turned on its side. The hot column sits a few pixels inside the
; tip of a plank and the heat is pushed outwards, one column per step, with a
; random vertical wobble and a random decay. The heat feeding a row is not
; constant: it drifts by a random amount every frame and is clamped low, so
; the ends smoulder in slow moving tongues instead of glowing evenly.
; Layout is fire[side][y][d], d counted outwards from the tip.
; ----------------------------------------------------------------------------
BurnEdges:
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15d, dword [rng_seed]
    lea r14, [fire]
    lea r10, [src_heat]
    push 2
    pop r13
.side:
    xor r12d, r12d
.heat:
    imul r15d, r15d, 1103515245         ; inline LCG, no call in these loops
    add r15d, 12345
    mov eax, r15d
    shr eax, 17
    and eax, 127
    sub eax, 63                         ; near unbiased walk: without this the
                                        ; rows all pin to 255 and the fire turns
                                        ; into a flat band instead of tongues
    movzx edx, byte [r10 + r12]
    add edx, eax
    cmp edx, 255                        ; let the tongues reach full heat
    jle .heat_low
    mov edx, 255
.heat_low:
    test edx, edx
    jns .heat_ok
    xor edx, edx
.heat_ok:
    mov byte [r10 + r12], dl
    inc r12d
    cmp r12d, SCR_H
    jb .heat

    ; Smooth the heat along y. Each row walks on its own, so without this the
    ; fire is fine static; diffusing a little every frame builds the vertical
    ; correlation that turns it into tongues of different lengths.
    push 2
    pop r9
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
    inc r12d
    cmp r12d, SCR_H
    jb .smooth
    dec r9d
    jnz .smooth_pass

    mov rbx, r14
    xor r12d, r12d
.row:
    movzx eax, byte [r10 + r12]
    mov byte [rbx], al                  ; source column, right at the tip
    push 1
    pop rcx
.cell:
    imul r15d, r15d, 1103515245
    add r15d, 12345
    mov eax, r15d
    shr eax, 16
    mov edx, eax
    and edx, 3
    dec edx                             ; vertical wobble, -1..2
    add edx, r12d
    cmp edx, SCR_H                      ; unsigned: also catches -1
    jb .y_ok
    mov edx, r12d
.y_ok:
    imul edx, edx, FIRE_W
    add edx, ecx
    movzx r8d, byte [r14 + rdx - 1]     ; heat of the column one step in
    shr eax, 6
    and eax, 3                          ; the source now starts deep inside the
                                        ; plank, so cooling has to be gentle
                                        ; enough to still reach past the tip
    sub r8d, eax
    jns .cool_ok
    xor r8d, r8d
.cool_ok:
    mov byte [rbx + rcx], r8b
    inc ecx
    cmp ecx, FIRE_W
    jb .cell

    add rbx, FIRE_W
    inc r12d
    cmp r12d, SCR_H
    jb .row

    add r14, SCR_H * FIRE_W
    add r10, SCR_H
    dec r13d
    jnz .side

    mov dword [rng_seed], r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Turn the rendered frame into premultiplied ARGB.
;
; GDI never touches the alpha byte, so this pass owns it: the plank mask gives
; the coverage, the embers add their own glow and a little coverage past the
; torn end, odd rows get their colour scaled down for the scanline grid, and
; the three channels are premultiplied, which is what UpdateLayeredWindow
; expects. The scanline only touches the colour, never the alpha, otherwise
; half of the window would go see-through.
; ----------------------------------------------------------------------------
AlphaPass:
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15

    lea r13, [mask]
    mov r14, qword [pixels]
    lea rbx, [fire]
    lea r15, [fire + SCR_H * FIRE_W]
    lea rbp, [tip_l]                    ; rbp is spare here, and tip_r follows
    xor r12d, r12d                      ; tip_l, so one base covers both
.row:
    mov r11d, 256                       ; colour scale for this row
    test r12b, 1
    jz .scan_ok
    sub r11d, 256 - SCANLINE
.scan_ok:
    mov esi, dword [rbp + r12 * 4]      ; where the two flame fronts start
    add esi, FLAME_IN
    mov edi, dword [rbp + r12 * 4 + (tip_r - tip_l)]
    sub edi, FLAME_IN
    xor ecx, ecx
.col:
    movzx r10d, byte [r13 + rcx]        ; coverage straight from the mask
    mov eax, esi
    sub eax, ecx
    cmp eax, FIRE_W                     ; unsigned: also catches negatives
    jb .flame_left
    mov eax, ecx
    sub eax, edi
    cmp eax, FIRE_W
    jae .no_flame
    mov edx, eax
    movzx eax, byte [r15 + rax]
    jmp .have_flame
.flame_left:
    mov edx, eax
    movzx eax, byte [rbx + rax]
.have_flame:
    cmp edx, FLAME_RISE                 ; fade the fire in as it comes out of
    jae .flame_lit                      ; the plank, so the body grades from
    imul eax, edx                       ; black to ash to ember instead of
    shr eax, FLAME_RISE_LOG             ; meeting the flames on a straight line
.flame_lit:
    lea eax, [rax + rax * 2]            ; +50%: the fade in costs brightness and
    shr eax, 1                          ; the embers have to read as fire
    cmp eax, 255
    jbe .flame_ok
    mov eax, 255
.flame_ok:
    test eax, eax
    jz .no_flame
    cmp eax, r10d                       ; embers glow a little past the tear
    cmova r10d, eax
.flame_paint:
    mov edx, 255                        ; the cold tail reads as ash: R ~ G ~ B
    sub edx, eax                        ; so the tips end in grey black smoke
    imul edx, eax                       ; that melts into the green blue core
    shr edx, 8
    shl edx, 16
    lea r8d, [rax + rax * 2]            ; B = 3f/4
    shr r8d, 2
    or edx, r8d
    mov dh, al                          ; G = f
    movd xmm0, dword [r14 + rcx * 4]    ; saturating add over all channels
    movd xmm1, edx
    paddusb xmm0, xmm1
    movd dword [r14 + rcx * 4], xmm0
.no_flame:
    mov eax, r10d                       ; one path for every pixel: coverage 0
    imul eax, r11d                      ; premultiplies to a transparent black
    shr eax, 8                          ; and coverage 255 to the pixel itself,
    movd xmm1, eax                      ; so the two shortcuts they used to have
    pshuflw xmm1, xmm1, 0x40            ; the factor spread over words 0..2 and
    movd xmm0, dword [r14 + rcx * 4]    ; left at zero in word 3, so the source
    pxor xmm2, xmm2                     ; alpha byte cannot survive the multiply
    punpcklbw xmm0, xmm2                ; and the OR below still owns it
    pmullw xmm0, xmm1
    psrlw xmm0, 8
    packuswb xmm0, xmm0
    movd edx, xmm0
    shl r10d, 24                        ; alpha keeps the untouched coverage
    or edx, r10d
    mov dword [r14 + rcx * 4], edx
.next:
    inc ecx
    cmp ecx, SCR_W
    jb .col
    add r13, SCR_W
    add r14, SCR_W * 4
    add rbx, FIRE_W
    add r15, FIRE_W
    inc r12d
    cmp r12d, SCR_H
    jb .row

    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; Frame layout:
;   rsp+0..111    shadow space and arguments
;   rsp+112..183  WNDCLASSA
;   rsp+192..239  MSG
;   rsp+240       cursor
;   rsp+248..287  BITMAPINFOHEADER
;   rsp+288       DIB bits pointer
;   rsp+296       SIZE for GetTextExtentPoint32A
; ----------------------------------------------------------------------------
; ----------------------------------------------------------------------------
; Packed note in ecx -> phase increment in ebx. Clobbers eax, ecx, edx.
; ----------------------------------------------------------------------------
NoteIncr:
    mov eax, ecx
    and eax, 15                         ; semitone picks the table entry,
    movzx ebx, word [rbp + rax * 2 + (note_incr - arp_tab)]
    shr ecx, 4
    shl ebx, cl
    ret

; ----------------------------------------------------------------------------
; Render the whole tune into .bss, then hand it to the mixer on an infinite
; hardware loop.
;
; Two oscillators and a noise channel, exactly what a chip had: a 50% square
; bass, a 25% pulse lead running an arpeggio, and a decaying noise burst for
; the hat. Everything is plucked, that is, the amplitude falls linearly across
; the row, which is what makes it read as a tracker and not as an organ.
;
; The buffer is rendered once at startup and played with WHDR_BEGINLOOP and
; dwLoops = -1, so the mixer repeats it on its own: no callback, no streaming
; thread, and not one instruction per frame spent on audio.
; ----------------------------------------------------------------------------
StartMusic:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rsi
    push rdi
    sub rsp, 72

    lea rbp, [arp_tab]                  ; the four tables are laid out back to
    lea rdi, [audio]                    ; back, so one base reaches all of them
    xor r12d, r12d                      ; row
    xor r14d, r14d                      ; bass phase
    xor r15d, r15d                      ; lead phase
.row:
    mov r8d, r12d
    shr r8d, 6                          ; which part of the tune we are in
    mov r9d, r12d
    shr r9d, 4
    and r9d, 3                          ; one chord every sixteen rows

    movzx ecx, byte [rbp + r9 + (bass_tab - arp_tab)]
    movsx edx, byte [rbp + r8 + (part_octave - arp_tab)]
    add ecx, edx
    call NoteIncr
    mov r13d, ebx                       ; bass increment for this row

    mov eax, r12d
    and eax, 3                          ; the arpeggio walks the chord, one
    test r8d, r8d                       ; note per row, and turns around to
    jz .arp_up                          ; walk back down on the low half
    xor eax, 3
.arp_up:
    lea eax, [rax + r9 * 4]
    movzx ecx, byte [rbp + rax]
    movsx edx, byte [rbp + r8 + (part_octave - arp_tab)]
    add ecx, edx
    call NoteIncr                       ; lead increment stays in ebx

    mov r11d, SND_ROWLEN
    xor r10d, r10d
.samp:
    mov r8d, 250                        ; linear pluck: every note decays over
    mov r9d, r10d                       ; its own row, so the tune has attack
    shr r9d, 2
    sub r8d, r9d
    shr r8d, 3

    add r14d, r13d                      ; 50% square, the fat one
    mov ecx, r8d
    bt r14d, 15
    jc .bass_hi
    neg ecx
.bass_hi:
    mov esi, ecx

    add r15d, ebx                       ; 25% pulse: the duty cycle is what
    mov eax, r15d                       ; makes the lead thin and nasal
    shr eax, 14
    and eax, 3
    mov ecx, r8d
    cmp eax, 3
    je .lead_hi
    neg ecx
.lead_hi:
    add esi, ecx

    test r12b, 1                        ; hat on the off rows only
    jz .no_hat
    cmp r10d, 120
    jae .no_hat
    call NextRand
    push 120
    pop rcx
    sub ecx, r10d
    shr ecx, 2                          ; a very short decaying noise burst
    test al, 1
    jnz .hat_hi
    neg ecx
.hat_hi:
    add esi, ecx
.no_hat:

    add esi, 128                        ; 8 bit PCM is unsigned, silence is 128
    mov byte [rdi], sil
    inc rdi
    inc r10d
    dec r11d
    jnz .samp

    inc r12d
    cmp r12d, SND_ROWS
    jb .row

    lea rcx, [wave_out]
    push -1
    pop rdx                             ; WAVE_MAPPER
    lea r8, [wave_fmt]
    xor r9d, r9d
    mov qword [rsp + 32], r9
    mov qword [rsp + 40], r9
    call waveOutOpen
    test eax, eax
    jnz .done                           ; no output device: just run silent

    lea rbx, [wave_hdr]                 ; one base for the whole header
    lea rax, [audio]
    mov qword [rbx], rax
    mov dword [rbx + 8], AUDIO_LEN
    mov byte [rbx + 24], 0x0C           ; WHDR_BEGINLOOP | WHDR_ENDLOOP
    or dword [rbx + 28], -1             ; and never stop looping
    mov rsi, qword [wave_out]

    mov rcx, rsi
    mov rdx, rbx
    push 48
    pop r8
    call waveOutPrepareHeader

    mov rcx, rsi
    mov rdx, rbx
    push 48
    pop r8
    call waveOutWrite
.done:
    add rsp, 72
    pop rdi
    pop rsi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
start:
DemoMain:
    push r12
    push rdi
    sub rsp, 328

    rdtsc                               ; a moving seed with no import at all:
    or eax, 1                           ; the planks are torn differently on
    mov dword [rng_seed], eax           ; every launch

    lea rdi, [rsp + 112]
    xor eax, eax
    push 9
    pop rcx
    rep stosq

    lea rax, [WndProc]
    mov qword [rsp + 120], rax          ; lpfnWndProc, NULL hInstance is fine
    lea rax, [class_name]               ; hCursor stays NULL: the pointer keeps
    mov qword [rsp + 176], rax          ; whatever shape it already had

    lea rcx, [rsp + 112]
    call RegisterClassA

    lea rdi, [rsp + 32]
    xor eax, eax
    push 8
    pop rcx
    rep stosq
    mov dword [rsp + 32], 150
    mov dword [rsp + 40], 110
    mov dword [rsp + 48], SCR_W
    mov dword [rsp + 56], SCR_H
    mov ecx, WS_EX_LAYERED
    lea rdx, [class_name]
    xor r8d, r8d
    mov r9d, WS_POPUP_VISIBLE
    call CreateWindowExA
    mov qword [window_handle], rax

    ; ---- back buffer we can both draw on with GDI and poke byte by byte
    xor ecx, ecx
    call CreateCompatibleDC
    mov r12, rax                        ; the DC is wanted five more times
    mov qword [mem_dc], rax

    mov rcx, r12
    lea rdx, [dib_head]                 ; a constant, so it lives in .text
    xor r8d, r8d
    lea r9, [rsp + 288]
    mov qword [rsp + 32], r8
    mov qword [rsp + 40], r8
    call CreateDIBSection
    mov rcx, r12
    mov rdx, rax
    call SelectObject
    mov rax, qword [rsp + 288]
    mov qword [pixels], rax

    mov rcx, r12
    push TRANSPARENT
    pop rdx
    call SetBkMode

    ; ---- the only system font left, and it never changes afterwards
    lea rdi, [rsp + 40]                 ; everything but weight and face name
    xor eax, eax
    push 8
    pop rcx
    rep stosq
    mov dword [rsp + 32], 700
    lea rax, [scroll_font]
    mov qword [rsp + 104], rax
    mov ecx, -SCROLL_H
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateFontA
    mov rcx, r12
    mov rdx, rax
    call SelectObject
    mov rcx, r12
    mov edx, 0x0040E060
    call SetTextColor

    call BuildLogo
    call MakeMask
    call InitField
    call StartMusic

    lea rdi, [x_pos]
    mov dword [rdi], PLANK_CORE
    mov dword [rdi + 4], 60
    push 1
    pop rax
    mov dword [rdi + 8], eax
    mov dword [rdi + 12], eax
    mov dword [rdi + 16], SCR_W

    mov rcx, qword [window_handle]
    push 1
    pop rdx
    push TIMER_MS
    pop r8
    xor r9d, r9d
    call SetTimer

.message_loop:
    lea rcx, [rsp + 192]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call GetMessageA
    test eax, eax
    jle .quit
    lea rcx, [rsp + 192]
    call DispatchMessageA
    jmp .message_loop

.quit:
    xor ecx, ecx
    call ExitProcess

; ----------------------------------------------------------------------------
; rcx = hwnd, edx = message, r8 = wParam, r9 = lParam
;
; Frame layout:
;   rsp+0..79     shadow space and arguments
;   rsp+80        hwnd
;   rsp+88        memory DC
;   rsp+96        SIZE of the layered surface
;   rsp+104       POINT source origin
;   rsp+112       BLENDFUNCTION
;   rsp+120/124   tail of the star trail
; ----------------------------------------------------------------------------
WndProc:
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, 176

    mov qword [rsp + 80], rcx

    cmp edx, WM_TIMER
    je .frame
    cmp edx, WM_KEYDOWN
    je .key
    cmp edx, WM_LBUTTONDOWN
    je .drag
    cmp edx, WM_DESTROY
    je .destroy
    call DefWindowProcA
    jmp .done

.key:
    cmp r8d, VK_ESCAPE
    jne .zero
.destroy:
    xor ecx, ecx                        ; no DestroyWindow, no PostQuitMessage,
    call ExitProcess                    ; no message pump teardown: just leave

.drag:
    call ReleaseCapture
    mov rcx, qword [rsp + 80]
    mov edx, WM_NCLBUTTONDOWN
    push HTCAPTION
    pop r8
    xor r9d, r9d
    call SendMessageA
    jmp .zero

; ------------------------------------------------------------------ update --
.frame:
    inc dword [frame_counter]

    mov eax, dword [scroll_x]
    sub eax, SCROLL_SPEED
    cmp eax, -(scroll_len * SCROLL_CW)
    jg .scroll_ok
    mov eax, SCR_W
.scroll_ok:
    mov dword [scroll_x], eax

    mov eax, dword [x_pos]              ; the word bounces inside the solid
    add eax, dword [x_vel]              ; core of the planks
    cmp eax, PLANK_CORE
    jl .x_flip
    cmp eax, SCR_W - PLANK_CORE - LOGO_W
    jle .x_ok
.x_flip:
    neg dword [x_vel]
    mov eax, dword [x_pos]
    add eax, dword [x_vel]
.x_ok:
    mov dword [x_pos], eax

    mov eax, dword [y_pos]
    add eax, dword [y_vel]
    cmp eax, 24
    jl .y_flip
    cmp eax, SCR_H - 118
    jle .y_ok
.y_flip:
    neg dword [y_vel]
    mov eax, dword [y_pos]
    add eax, dword [y_vel]
.y_ok:
    mov dword [y_pos], eax

    lea rbx, [rain]                     ; drops fall in 1/64 of a block row
    push LOGO_COLS
    pop r12
.rain_step:
    mov eax, dword [rbx + RN_Y]
    add eax, dword [rbx + RN_V]
    cmp eax, (GLYPH_ROWS + RAIN_TRAIL) * 64
    jl .rain_store
    call NextRand
    and eax, 15
    add eax, 3
    mov dword [rbx + RN_V], eax
    xor eax, eax
.rain_store:
    mov dword [rbx + RN_Y], eax
    add rbx, RN_N * 4
    dec r12d
    jnz .rain_step

    lea rbx, [stars]
    mov r12d, STARS
.star_step:
    call SyncTrail
    sub dword [rbx + ST_Z], STAR_SPEED
    cmp dword [rbx + ST_Z], STAR_NEAR
    jle .star_reset

    call ProjectStar
    mov eax, dword [rbx + ST_SX]
    cmp eax, SCR_W
    jae .star_reset                     ; unsigned: catches negatives too
    mov eax, dword [rbx + ST_SY]
    cmp eax, SCR_H
    jb .star_next
.star_reset:
    call ResetStar
    call ProjectStar
    call SyncTrail
.star_next:
    add rbx, ST_N * 4
    dec r12d
    jnz .star_step

; ------------------------------------------------------------------ render --
    push rdi                            ; clear the frame, eight bytes at a time
    mov rdi, qword [pixels]
    xor eax, eax
    mov ecx, SCR_W * SCR_H / 2
    rep stosq
    pop rdi

    mov rcx, qword [mem_dc]
    mov edx, dword [scroll_x]
    mov r8d, SCROLL_Y
    lea r9, [scroll_text]
    mov dword [rsp + 32], scroll_len
    call TextOutA

    ; GDI batches its work, so flush before writing to the bits by hand
    call GdiFlush

    lea rbx, [stars]
    mov r12d, STARS
.star_draw:
    mov eax, dword [rbx + ST_Z]
    shr eax, 2
    mov edx, 255
    sub edx, eax                        ; brightness from depth
    cmp edx, 40
    jge .lum_ok
    push 40
    pop rdx
.lum_ok:
    imul edx, edx, 0x010101             ; white stars: R = G = B
    mov r14d, edx                       ; the colour is needed twice

    mov ecx, dword [rbx + ST_SX]        ; head, then tail
    mov edx, dword [rbx + ST_SY]
    mov r8d, dword [rbx + ST_PX]
    mov r9d, dword [rbx + ST_PY]
    mov eax, r14d
    call DrawTrail

    cmp dword [rbx + ST_Z], STAR_FAT    ; the closest ones are drawn twice
    jg .star_thin
    mov ecx, dword [rbx + ST_SX]
    inc ecx
    mov edx, dword [rbx + ST_SY]
    mov r8d, dword [rbx + ST_PX]
    inc r8d
    mov r9d, dword [rbx + ST_PY]
    mov eax, r14d
    call DrawTrail
.star_thin:
    add rbx, ST_N * 4
    dec r12d
    jnz .star_draw

    ; ------------------------------------------------------------- the logo --
    ; every lit block of the font first, in the dim base colour
    lea r15, [colbits]
    xor r12d, r12d
.logo_col:
    mov r13d, dword [r15 + r12 * 4]
    xor r14d, r14d
.logo_row:
    shr r13d, 1
    jnc .logo_next
    mov ecx, r12d
    mov edx, r14d
    mov r8d, 0x000A4018
    call DrawBlock
.logo_next:
    inc r14d
    cmp r14d, GLYPH_ROWS
    jb .logo_row
    inc r12d
    cmp r12d, LOGO_COLS
    jb .logo_col

    ; then the Matrix drops, one colour per depth in the trail
    xor r13d, r13d
.rain_depth:
    lea rbx, [rain]
    xor r12d, r12d
.rain_col:
    mov eax, dword [rbx + RN_Y]
    sar eax, 6                          ; head, in block rows
    sub eax, r13d
    cmp eax, GLYPH_ROWS
    jae .rain_next
    mov ecx, dword [r15 + r12 * 4]
    bt ecx, eax
    jnc .rain_next

    mov edx, eax
    mov ecx, r12d
    lea rax, [level_col]
    mov r8d, dword [rax + r13 * 4]
    call DrawBlock
.rain_next:
    add rbx, RN_N * 4
    inc r12d
    cmp r12d, LOGO_COLS
    jb .rain_col
    inc r13d
    cmp r13d, RAIN_TRAIL
    jb .rain_depth

    ; loose blocks floating around the word, reshuffled every eight frames
    mov r13d, dword [frame_counter]
    shr r13d, 3
    xor r12d, r12d
.glitch:
    imul eax, r12d, -1640531527
    add eax, r13d
    imul eax, eax, 1103515245
    mov r14d, eax
    shr eax, 9
    xor edx, edx
    push LOGO_COLS
    pop rcx
    div ecx                             ; edx = block column
    mov ebx, edx

    shr r14d, 21                        ; block row, may sit outside the word
    and r14d, 15
    sub r14d, 4

    mov ecx, dword [r15 + rbx * 4]      ; skip anything hidden by a letter
    cmp r14d, GLYPH_ROWS
    jae .glitch_draw
    bt ecx, r14d
    jc .glitch_next
.glitch_draw:
    mov ecx, ebx
    mov edx, r14d
    mov r8d, 0x00186A2A
    call DrawBlock
.glitch_next:
    inc r12d
    cmp r12d, GLITCH
    jb .glitch

    call BurnEdges
    call AlphaPass

    mov rcx, qword [rsp + 80]           ; hand the surface to the compositor
    xor edx, edx
    xor r8d, r8d
    lea r9, [ulw_size]
    mov rax, qword [mem_dc]
    mov qword [rsp + 32], rax
    lea rax, [r9 + 12]
    mov qword [rsp + 40], rax
    mov qword [rsp + 48], r8
    lea rax, [r9 + 8]
    mov qword [rsp + 56], rax
    mov dword [rsp + 64], ULW_ALPHA
    call UpdateLayeredWindow

.zero:
    xor eax, eax

.done:
    add rsp, 176
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret
