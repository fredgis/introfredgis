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
;   - perspective starfield with radial trails
;
; Build (PowerShell). tiny.ld drops the sections mingw emits for a C runtime
; we do not have, which is worth a kilobyte in the final image:
;   $lib = Join-Path (Split-Path (Split-Path (Get-Command ld).Source)) `
;          "x86_64-w64-mingw32\lib"
;   nasm -Ox -f win64 fredgis4k.asm -o fredgis4k.o
;   ld -mi386pep --subsystem windows -e start -s -T tiny.ld -o fredgis4k.exe `
;      fredgis4k.o "-L$lib" -lkernel32 -luser32 -lgdi32
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
                                         ; not need GetTextExtentPoint32A

extern ExitProcess
extern CreateWindowExA
extern UpdateLayeredWindow
extern GetMessageA
extern SetTimer
extern SelectObject
extern CreateCompatibleDC
extern CreateDIBSection

; ----------------------------------------------------------------------------
; Constants live inside .text: no extra section, hence no extra PE padding.
; ----------------------------------------------------------------------------
section .text

class_name    db "STATIC", 0        ; predefined class: no WNDCLASS, no WndProc

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


ulw_size      dd SCR_W, SCR_H             ; constant arguments of the blit
ulw_src       dd 0, 0
ulw_blend     dd BLEND_ARGB

dib_head      dd 40                       ; BITMAPINFOHEADER, a pure constant:
              dd SCR_W                    ; built here rather than on the stack
              dd -SCR_H                   ; negative height: top down rows
              dw 1, 32                    ; biPlanes, biBitCount, BI_RGB
              dd 0, 0, 0, 0, 0, 0

section .bss
window_handle resq 1
mem_dc        resq 1
pixels        resq 1                      ; DIB bits, top down, 32 bpp
rng_seed      resd 1
frame_counter resd 1
box_x0        resd 1                      ; area the logo may wander in
box_x1        resd 1
x_pos         resd 1
y_pos         resd 1
x_vel         resd 1
y_vel         resd 1
mask          resb SCR_W * SCR_H          ; static plank silhouette, 0..255
tip_l         resd SCR_H                  ; first and last lit column of a row
tip_r         resd SCR_H
fire          resb 2 * SCR_H * FIRE_W     ; edge flames, left band then right
src_heat      resb 2 * SCR_H              ; drifting heat feeding the flames
colbits       resd LOGO_COLS              ; one bit per block row of the logo
rain          resd LOGO_COLS * RN_N       ; drop head in 1/64 of a block row,
                                          ; then its speed
stars         resd STARS * ST_N           ; x, y, z, screen x/y, previous x/y

section .text
global start

start:
    sub rsp, 40
    call DemoMain
    mov ecx, eax
    call ExitProcess

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
; ecx = x, edx = y, r8d = 0x00RRGGBB. Clobbers rax and r10 only.
; ----------------------------------------------------------------------------
DrawBlock:
    imul ecx, ecx, SCALE                ; block coordinates, scaled and offset
    add ecx, dword [x_pos]              ; here rather than at the three call
    imul edx, edx, SCALE                ; sites that used to do it themselves
    add edx, dword [y_pos]
    mov eax, edx
    imul eax, eax, SCR_W
    add eax, ecx
    shl eax, 2
    push rdi
    mov rdi, qword [pixels]             ; a row is SCALE contiguous dwords, so
    add rdi, rax                        ; it is one rep stosd. That leaves rdi
    mov eax, r8d                        ; on the pixel after the block, and the
    push SCALE                          ; step to the next row is only the rest
    pop r10                             ; of the scanline
.row:
    push SCALE
    pop rcx
    rep stosd
    add rdi, (SCR_W - SCALE) * 4
    dec r10d
    jnz .row
    pop rdi
    ret

; ----------------------------------------------------------------------------
; Expand the block font into one row bitmask per logo column, so drawing only
; ever needs a bit test.
; ----------------------------------------------------------------------------
BuildLogo:
    push rdi
    lea r8, [glyph_data]
    lea r9, [colbits]
    mov rdi, r9
    xor eax, eax
    mov ecx, LOGO_COLS
    rep stosd

    xor r10d, r10d                      ; letter index
.letter:
    xor r11d, r11d                      ; block row
.row:
    mov eax, r10d
    shl eax, 3
    add eax, r11d
    movzx ecx, byte [r8 + rax]
    xor edx, edx                        ; bit, 0 = leftmost
.bit:
    push 7
    pop rax
    sub eax, edx
    bt ecx, eax
    jnc .next_bit
    mov eax, r10d
    imul eax, eax, GLYPH_PITCH
    add eax, edx
    bts dword [r9 + rax * 4], r11d
.next_bit:
    inc edx
    cmp edx, 8
    jb .bit
    inc r11d
    cmp r11d, GLYPH_ROWS
    jb .row
    inc r10d
    cmp r10d, 7
    jb .letter
    pop rdi
    ret

; ----------------------------------------------------------------------------
; The star rbx points at respawns far away.
; ----------------------------------------------------------------------------
ResetStar:
    call NextRand
    and eax, (STAR_SPREAD * 2 - 1)
    sub eax, STAR_SPREAD
    mov dword [rbx + ST_X], eax
    call NextRand
    and eax, (STAR_SPREAD * 2 - 1)
    sub eax, STAR_SPREAD
    mov dword [rbx + ST_Y], eax
    call NextRand
    and eax, 255
    add eax, 384
    mov dword [rbx + ST_Z], eax
    ret

; ----------------------------------------------------------------------------
; Perspective projection of the star rbx points at.
; ----------------------------------------------------------------------------
ProjectStar:
    mov eax, dword [rbx + ST_X]
    imul eax, eax, STAR_FOV
    cdq
    idiv dword [rbx + ST_Z]
    add eax, CX
    mov dword [rbx + ST_SX], eax
    mov eax, dword [rbx + ST_Y]
    imul eax, eax, STAR_FOV
    cdq
    idiv dword [rbx + ST_Z]
    add eax, CY
    mov dword [rbx + ST_SY], eax
    ret

; ----------------------------------------------------------------------------
; Freeze the current position as the tail of the trail.
; ----------------------------------------------------------------------------
SyncTrail:
    mov eax, dword [rbx + ST_SX]
    mov dword [rbx + ST_PX], eax
    mov eax, dword [rbx + ST_SY]
    mov dword [rbx + ST_PY], eax
    ret

; ----------------------------------------------------------------------------
; Scatter the stars and prime the rain columns.
; ----------------------------------------------------------------------------
InitField:
    push rbp
    mov rbp, rsp
    push r12
    push rbx
    sub rsp, 32

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
    mov r12d, LOGO_COLS
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

    add rsp, 32
    pop rbx
    pop r12
    pop rbp
    ret

; ----------------------------------------------------------------------------
; Build the static plank silhouette once.
;
; The planks are stacked edge to edge with no seam between them, so the only
; thing that shapes the window is where each slab stops on the left and on the
; right. A plank that stops early gets a long fade, one that reaches far out
; gets a short one, which keeps the opaque core exactly PLANK_CORE pixels wide
; on both sides while the visible tips land all over the place.
;
; Frame: rsp+32..63 scratch, only there as shadow space for the calls
; ----------------------------------------------------------------------------
MakeMask:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rsi
    push rdi
    sub rsp, 40

    lea r13, [mask]
    lea rsi, [tip_l]
    lea rdi, [tip_r]
    xor r12d, r12d
.plank:
    call NextRand
    and eax, 15
    imul eax, eax, 2                    ; 16..TIP_MAX. The spread stays small:
    add eax, 16                         ; a big one turns the stack into a
    mov r14d, eax                       ; visible staircase of black steps

    call NextRand
    and eax, 15
    imul eax, eax, 2
    add eax, 16
    mov r15d, SCR_W
    sub r15d, eax                       ; where it stops on the right

    mov eax, r12d
    imul eax, eax, PLANK_H * SCR_W
    lea r10, [r13 + rax]                ; first row of this plank

    mov ebx, r12d                       ; global row index: the tips are stored
    imul ebx, ebx, PLANK_H              ; per row, not per plank
    mov r9, rsi
    mov r8, rdi
    mov r11d, PLANK_H
.tip:
    call NextRand
    and eax, 7                          ; wobble each row a few pixels: a tip
    sub eax, 4                           ; that is constant down the plank
    add eax, r14d                       ; draws a ruler straight edge, and a
    mov dword [r9 + rbx * 4], eax       ; straight edge is what reads as square
    call NextRand
    and eax, 7
    sub eax, 4
    add eax, r15d
    dec eax
    mov dword [r8 + rbx * 4], eax
    inc rbx
    dec r11d
    jnz .tip

    sub rbx, PLANK_H                    ; rewind: the row loop walks it again
    mov r11d, PLANK_H
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

    mov dword [box_x0], PLANK_CORE
    mov dword [box_x1], SCR_W - PLANK_CORE

    add rsp, 40
    pop rdi
    pop rsi
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

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
    jle .have_n
    mov eax, ecx
.have_n:
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
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r15d, dword [rng_seed]
    lea r14, [fire]
    lea r10, [src_heat]
    xor r13d, r13d
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

    xor r12d, r12d
.row:
    mov eax, r12d
    imul eax, eax, FIRE_W
    lea rbx, [r14 + rax]
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

    inc r12d
    cmp r12d, SCR_H
    jb .row

    add r14, SCR_H * FIRE_W
    add r10, SCR_H
    inc r13d
    cmp r13d, 2
    jb .side

    mov dword [rng_seed], r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
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
    test r12d, 1
    jz .scan_ok
    mov r11d, SCANLINE
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
    jbe .flame_paint
    mov r10d, eax
.flame_paint:
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
    movd xmm0, dword [r14 + rcx * 4]    ; saturating add over all channels
    movd xmm1, edx
    paddusb xmm0, xmm1
    movd dword [r14 + rcx * 4], xmm0
.no_flame:
    mov eax, r10d                       ; one path for every pixel: coverage 0
    imul eax, r11d                      ; premultiplies to a transparent black
    shr eax, 8                          ; and coverage 255 to the pixel itself,
    mov edx, dword [r14 + rcx * 4]      ; so the two shortcuts they used to have
    movd xmm1, eax                      ; were pure code size
    pshuflw xmm1, xmm1, 0x40            ; the factor spread over words 0..2 and
    movd xmm0, edx                      ; left at zero in word 3, so the source
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
DemoMain:
    push rbp
    mov rbp, rsp
    push r12
    push rdi
    sub rsp, 320

    rdtsc                               ; a moving seed with no import at all:
    or eax, 1                           ; the planks are torn differently on
    mov dword [rng_seed], eax           ; every launch
    lea rdi, [rsp + 64]                 ; the last four arguments are NULL
    xor eax, eax
    push 4
    pop rcx
    rep stosq
    mov qword [rsp + 32], 150
    mov qword [rsp + 40], 110
    mov qword [rsp + 48], SCR_W
    mov qword [rsp + 56], SCR_H
    mov ecx, WS_EX_LAYERED
    lea rdx, [class_name]               ; a predefined class, so there is no
    xor r8d, r8d                        ; window procedure to register and no
    mov r9d, WS_POPUP_VISIBLE           ; WNDCLASS to fill in
    call CreateWindowExA
    mov qword [window_handle], rax

    ; ---- back buffer we poke byte by byte, no GDI drawing left at all
    xor ecx, ecx
    call CreateCompatibleDC
    mov r12, rax
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

    call BuildLogo
    call MakeMask
    call InitField

    mov eax, dword [box_x0]
    mov dword [x_pos], eax
    mov dword [y_pos], 60
    push 1
    pop rax
    mov dword [x_vel], eax
    mov dword [y_vel], eax

    mov rcx, qword [window_handle]
    push 1
    pop rdx
    mov r8d, TIMER_MS
    xor r9d, r9d
    call SetTimer

    ; The timer posts WM_TIMER into the queue, so the frame can be drawn right
    ; here instead of in a window procedure. That removes RegisterClassA,
    ; DefWindowProcA and DispatchMessageA, and leaves eight imports in all.
.message_loop:
    lea rcx, [rsp + 192]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call GetMessageA
    test eax, eax
    jle .quit
    mov eax, dword [rsp + 200]          ; MSG.message
    cmp eax, WM_KEYDOWN
    je .quit
    cmp eax, WM_TIMER
    jne .message_loop
    call DrawFrame
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
DrawFrame:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    push rbx
    sub rsp, 184

    inc dword [frame_counter]

    mov eax, dword [x_pos]              ; the word bounces inside the solid
    add eax, dword [x_vel]              ; core of the planks
    cmp eax, dword [box_x0]
    jl .x_flip
    mov ecx, dword [box_x1]
    sub ecx, LOGO_W
    cmp eax, ecx
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
    mov r12d, LOGO_COLS
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
    mov eax, dword [rbx + ST_Z]
    sub eax, STAR_SPEED
    mov dword [rbx + ST_Z], eax
    cmp eax, STAR_NEAR
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
    mov eax, edx                        ; white stars: R = G = B
    shl eax, 8
    or edx, eax
    shl eax, 8
    or edx, eax
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
    bt r13d, r14d
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
    js .rain_next
    cmp eax, GLYPH_ROWS
    jae .rain_next
    lea rcx, [colbits]
    mov ecx, dword [rcx + r12 * 4]
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
    mov eax, r12d
    imul eax, eax, -1640531527
    add eax, r13d
    imul eax, eax, 1103515245
    mov r14d, eax
    shr eax, 9
    xor edx, edx
    mov ecx, LOGO_COLS
    div ecx                             ; edx = block column
    mov r15d, edx

    mov eax, r14d                       ; block row, may sit outside the word
    shr eax, 21
    and eax, 15
    sub eax, 4
    mov r14d, eax

    lea rcx, [colbits]                  ; skip anything hidden by a letter
    mov ecx, dword [rcx + r15 * 4]
    test r14d, r14d
    js .glitch_draw
    cmp r14d, GLYPH_ROWS
    jae .glitch_draw
    bt ecx, r14d
    jc .glitch_next
.glitch_draw:
    mov ecx, r15d
    mov edx, r14d
    mov r8d, 0x00186A2A
    call DrawBlock
.glitch_next:
    inc r12d
    cmp r12d, GLITCH
    jb .glitch

    call BurnEdges
    call AlphaPass

    mov rcx, qword [window_handle]      ; hand the surface to the compositor
    xor edx, edx
    xor r8d, r8d
    lea r9, [ulw_size]
    mov rax, qword [mem_dc]
    mov qword [rsp + 32], rax
    lea rax, [ulw_src]
    mov qword [rsp + 40], rax
    mov qword [rsp + 48], r8
    lea rax, [ulw_blend]
    mov qword [rsp + 56], rax
    mov qword [rsp + 64], ULW_ALPHA
    call UpdateLayeredWindow

    add rsp, 184
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret
