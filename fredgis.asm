; ============================================================================
; FREDGIS - Win64 cracktro, 100 % NASM, no C, no CRT
; ----------------------------------------------------------------------------
;   - the window is a stack of horizontal PLANKS whose left and right ends
;     dissolve into real transparency; that needs per-pixel alpha, so the demo
;     is a layered window fed by UpdateLayeredWindow from a 32 bpp DIB we own
;   - worn CRT look: every other line is darkened for the scanline feel
;   - the torn ends of the planks smoulder: a sideways Doom fire pushes green
;     blue embers outwards so the silhouette never looks rectangular
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
;      fredgis.o "-L$lib" -lkernel32 -luser32 -lgdi32
; ============================================================================

bits 64
default rel

%define WS_POPUP_VISIBLE    0x90000000   ; WS_POPUP | WS_VISIBLE
%define WS_EX_LAYERED       0x00080000
%define ULW_ALPHA           2
%define BLEND_ARGB          0x01FF0000   ; AC_SRC_OVER, 255, AC_SRC_ALPHA
%define IDC_ARROW           32512
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
%define PLANK_CORE          118          ; opaque width sacrificed at each end
%define FIRE_W              48           ; how far a flame can reach past the tip
%define FLAME_IN            10           ; how deep inside the plank it starts
%define SCANLINE            205          ; colour scale of every odd row

%define STARS               200
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
%define SCROLL_Y            (SCR_H - 46)
%define SCROLL_SPEED        2

extern ExitProcess
extern GetTickCount
extern LoadCursorA
extern RegisterClassA
extern CreateWindowExA
extern UpdateLayeredWindow
extern DestroyWindow
extern ReleaseCapture
extern SendMessageA
extern GetMessageA
extern DispatchMessageA
extern DefWindowProcA
extern SetTimer
extern PostQuitMessage
extern CreateFontA
extern SelectObject
extern SetBkMode
extern SetTextColor
extern TextOutA
extern GetTextExtentPoint32A
extern CreateCompatibleDC
extern CreateDIBSection
extern GdiFlush

; ----------------------------------------------------------------------------
; Constants live inside .text: no extra section, hence no extra PE padding.
; ----------------------------------------------------------------------------
section .text

class_name    db "FG", 0
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

scroll_text   db "*** FREDGIS PRESENTS ***     DATA IS THE CENTER OF "
              db "EVERYTHING ***     NO DATA, NO INTELLIGENCE - ARTIFICIAL "
              db "OR NOT ***     MODELS COME AND GO, THE DATA REMAINS ***     "
              db "GARBAGE IN, GARBAGE OUT STILL RULES ***     ESC TO RETURN, "
              db "DRAG TO MOVE ***     ", 0
scroll_len    equ $ - scroll_text - 1

ulw_size      dd SCR_W, SCR_H             ; constant arguments of the blit
ulw_src       dd 0, 0
ulw_blend     dd BLEND_ARGB

section .bss
window_handle resq 1
mem_dc        resq 1
pixels        resq 1                      ; DIB bits, top down, 32 bpp
rng_seed      resd 1
frame_counter resd 1
scroll_w      resd 1
box_x0        resd 1                      ; area the logo may wander in
box_x1        resd 1
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
rain_y        resd LOGO_COLS              ; drop head, 1/64 of a block row
rain_v        resd LOGO_COLS
stars_x       resd STARS
stars_y       resd STARS
stars_z       resd STARS
stars_sx      resd STARS
stars_sy      resd STARS
stars_px      resd STARS
stars_py      resd STARS

section .text
global start
global WndProc

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
; ecx = x, edx = y, r8d = 0x00RRGGBB. Clobbers rax, r9, r10, r11 only.
; ----------------------------------------------------------------------------
DrawBlock:
    mov eax, edx
    imul eax, eax, SCR_W
    add eax, ecx
    shl eax, 2
    mov r9, qword [pixels]
    add r9, rax
    mov r10d, SCALE
.row:
    mov rax, r9
    mov r11d, SCALE
.col:
    mov dword [rax], r8d
    add rax, 4
    dec r11d
    jnz .col
    add r9, SCR_W * 4
    dec r10d
    jnz .row
    ret

; ----------------------------------------------------------------------------
; Expand the block font into one row bitmask per logo column, so drawing only
; ever needs a bit test.
; ----------------------------------------------------------------------------
BuildLogo:
    lea r8, [glyph_data]
    lea r9, [colbits]
    xor r10d, r10d
    xor eax, eax
.clear:
    mov dword [r9 + r10 * 4], eax
    inc r10d
    cmp r10d, LOGO_COLS
    jb .clear

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
    mov eax, 7
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
    ret

; ----------------------------------------------------------------------------
; Star r12d respawns far away. r13/r14/r15 = X/Y/Z bases.
; ----------------------------------------------------------------------------
ResetStar:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    call NextRand
    and eax, (STAR_SPREAD * 2 - 1)
    sub eax, STAR_SPREAD
    mov dword [r13 + r12 * 4], eax
    call NextRand
    and eax, (STAR_SPREAD * 2 - 1)
    sub eax, STAR_SPREAD
    mov dword [r14 + r12 * 4], eax
    call NextRand
    and eax, 255
    add eax, 384
    mov dword [r15 + r12 * 4], eax
    add rsp, 32
    pop rbp
    ret

; ----------------------------------------------------------------------------
; Perspective projection of star r12d.
; ----------------------------------------------------------------------------
ProjectStar:
    mov eax, dword [r13 + r12 * 4]
    imul eax, eax, STAR_FOV
    cdq
    idiv dword [r15 + r12 * 4]
    add eax, CX
    lea rcx, [stars_sx]
    mov dword [rcx + r12 * 4], eax
    mov eax, dword [r14 + r12 * 4]
    imul eax, eax, STAR_FOV
    cdq
    idiv dword [r15 + r12 * 4]
    add eax, CY
    lea rcx, [stars_sy]
    mov dword [rcx + r12 * 4], eax
    ret

; ----------------------------------------------------------------------------
; Freeze the current position as the tail of the trail.
; ----------------------------------------------------------------------------
SyncTrail:
    lea rcx, [stars_sx]
    mov eax, dword [rcx + r12 * 4]
    lea rcx, [stars_px]
    mov dword [rcx + r12 * 4], eax
    lea rcx, [stars_sy]
    mov eax, dword [rcx + r12 * 4]
    lea rcx, [stars_py]
    mov dword [rcx + r12 * 4], eax
    ret

; ----------------------------------------------------------------------------
; Scatter the stars and prime the rain columns.
; ----------------------------------------------------------------------------
InitField:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32

    lea r13, [stars_x]
    lea r14, [stars_y]
    lea r15, [stars_z]
    xor r12d, r12d
.stars:
    call ResetStar
    call NextRand                       ; spread the depths out
    and eax, 511
    add eax, STAR_NEAR + 8
    mov dword [r15 + r12 * 4], eax
    call ProjectStar
    call SyncTrail
    inc r12d
    cmp r12d, STARS
    jb .stars

    lea r13, [rain_y]
    lea r14, [rain_v]
    xor r12d, r12d
.rain:
    call NextRand
    and eax, 1023
    mov dword [r13 + r12 * 4], eax
    call NextRand
    and eax, 15
    add eax, 3
    mov dword [r14 + r12 * 4], eax
    inc r12d
    cmp r12d, LOGO_COLS
    jb .rain

    add rsp, 32
    pop r15
    pop r14
    pop r13
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
; Frame: rsp+32 left fade width, rsp+36 right fade width
; ----------------------------------------------------------------------------
MakeMask:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64

    lea r13, [mask]
    xor r12d, r12d
.plank:
    call NextRand
    and eax, 15
    imul eax, eax, 7                    ; 0..105
    mov r14d, eax                       ; where this plank stops on the left
    mov ecx, PLANK_CORE
    sub ecx, eax
    mov dword [rsp + 32], ecx           ; left fade, 13..118

    call NextRand
    and eax, 15
    imul eax, eax, 7
    mov r15d, SCR_W
    sub r15d, eax                       ; where it stops on the right
    mov ecx, PLANK_CORE
    sub ecx, eax
    mov dword [rsp + 36], ecx           ; right fade

    mov eax, r12d
    imul eax, eax, PLANK_H * SCR_W
    lea r10, [r13 + rax]                ; first row of this plank

    mov eax, r12d                       ; remember the two tips: the flames
    imul eax, eax, PLANK_H              ; burn outwards from there
    lea r9, [tip_l]
    lea r8, [tip_r]
    mov r11d, PLANK_H
.tip:
    mov dword [r9 + rax * 4], r14d
    mov ecx, r15d
    dec ecx
    mov dword [r8 + rax * 4], ecx
    inc eax
    dec r11d
    jnz .tip

    mov r11d, PLANK_H
.row:
    xor ecx, ecx
.col:
    mov eax, ecx                        ; ramp up from the left tip
    sub eax, r14d
    test eax, eax
    jle .clear
    cmp eax, dword [rsp + 32]
    jge .left_full
    imul eax, eax, 255
    cdq
    idiv dword [rsp + 32]
    jmp .have_left
.left_full:
    mov eax, 255
.have_left:
    mov r8d, eax
    mov eax, r15d                       ; ramp up from the right tip
    dec eax
    sub eax, ecx
    test eax, eax
    jle .clear
    cmp eax, dword [rsp + 36]
    jge .take_left
    imul eax, eax, 255
    cdq
    idiv dword [rsp + 36]
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

    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
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
    mov r9d, eax
    sar r9d, 31
    xor eax, r9d
    sub eax, r9d
    mov ecx, r11d
    mov r9d, ecx
    sar r9d, 31
    xor ecx, r9d
    sub ecx, r9d
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
    and eax, 63
    sub eax, 30                         ; random walk, slightly upward biased
    movzx edx, byte [r10 + r12]
    add edx, eax
    cmp edx, 150                        ; keep it dim: these are embers
    jle .heat_low
    mov edx, 150
.heat_low:
    test edx, edx
    jns .heat_ok
    xor edx, edx
.heat_ok:
    mov byte [r10 + r12], dl
    inc r12d
    cmp r12d, SCR_H
    jb .heat

    xor r12d, r12d
.row:
    mov eax, r12d
    imul eax, eax, FIRE_W
    lea rbx, [r14 + rax]
    movzx eax, byte [r10 + r12]
    mov byte [rbx], al                  ; source column, right at the tip
    mov ecx, 1
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
    and eax, 15
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
    mov rbp, rsp
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
    xor r12d, r12d
.row:
    mov r11d, 256                       ; colour scale for this row
    test r12d, 1
    jz .scan_ok
    mov r11d, SCANLINE
.scan_ok:
    lea rax, [tip_l]                    ; where the two flame fronts start
    mov esi, dword [rax + r12 * 4]
    add esi, FLAME_IN
    lea rax, [tip_r]
    mov edi, dword [rax + r12 * 4]
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
    movzx eax, byte [r15 + rax]
    jmp .have_flame
.flame_left:
    movzx eax, byte [rbx + rax]
.have_flame:
    test eax, eax
    jz .no_flame
    cmp eax, r10d                       ; embers glow a little past the tear
    jbe .flame_paint
    mov r10d, eax
.flame_paint:
    mov edx, eax                        ; R = f/16, G = 3f/4, B = f/2
    shr edx, 4
    shl edx, 16
    mov r8d, eax
    shr r8d, 1
    or edx, r8d
    lea r8d, [rax + rax * 2]
    shr r8d, 2
    shl r8d, 8
    or edx, r8d
    movd xmm0, dword [r14 + rcx * 4]    ; saturating add over all channels
    movd xmm1, edx
    paddusb xmm0, xmm1
    movd dword [r14 + rcx * 4], xmm0
.no_flame:
    test r10d, r10d
    jz .clear
    mov eax, r10d
    imul eax, r11d
    shr eax, 8
    cmp eax, 255
    jae .opaque
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
    jmp .next
.opaque:
    or dword [r14 + rcx * 4], 0xFF000000
    jmp .next
.clear:
    mov dword [r14 + rcx * 4], 0
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
DemoMain:
    push rbp
    mov rbp, rsp
    push r12
    push rdi
    sub rsp, 320

    call GetTickCount                   ; moving seed: the planks are torn
    or eax, 1                           ; differently on every launch
    mov dword [rng_seed], eax

    xor ecx, ecx
    mov edx, IDC_ARROW
    call LoadCursorA
    mov qword [rsp + 240], rax

    lea rdi, [rsp + 112]
    xor eax, eax
    mov ecx, 9
    rep stosq

    lea rax, [WndProc]
    mov qword [rsp + 120], rax          ; lpfnWndProc, NULL hInstance is fine
    mov rax, qword [rsp + 240]
    mov qword [rsp + 152], rax          ; hCursor
    lea rax, [class_name]
    mov qword [rsp + 176], rax          ; lpszClassName

    lea rcx, [rsp + 112]
    call RegisterClassA
    test ax, ax
    jz .fail

    lea rdi, [rsp + 64]                 ; the last four arguments are NULL
    xor eax, eax
    mov ecx, 4
    rep stosq
    mov qword [rsp + 32], 150
    mov qword [rsp + 40], 110
    mov qword [rsp + 48], SCR_W
    mov qword [rsp + 56], SCR_H
    mov ecx, WS_EX_LAYERED
    lea rdx, [class_name]
    xor r8d, r8d
    mov r9d, WS_POPUP_VISIBLE
    call CreateWindowExA
    test rax, rax
    jz .fail
    mov qword [window_handle], rax

    ; ---- back buffer we can both draw on with GDI and poke byte by byte
    xor ecx, ecx
    call CreateCompatibleDC
    mov qword [mem_dc], rax

    lea rdi, [rsp + 248]
    xor eax, eax
    mov ecx, 5
    rep stosq
    mov dword [rsp + 248], 40           ; biSize
    mov dword [rsp + 252], SCR_W
    mov dword [rsp + 256], -SCR_H       ; negative height: top down rows
    mov word [rsp + 260], 1             ; biPlanes
    mov word [rsp + 262], 32            ; biBitCount, BI_RGB

    mov rcx, qword [mem_dc]
    lea rdx, [rsp + 248]
    xor r8d, r8d
    lea r9, [rsp + 288]
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
    call CreateDIBSection
    test rax, rax
    jz .fail
    mov rcx, qword [mem_dc]
    mov rdx, rax
    call SelectObject
    mov rax, qword [rsp + 288]
    mov qword [pixels], rax

    mov rcx, qword [mem_dc]
    mov edx, TRANSPARENT
    call SetBkMode

    ; ---- the only system font left, and it never changes afterwards
    sub rsp, 128
    lea rdi, [rsp + 40]                 ; everything but weight and face name
    xor eax, eax
    mov ecx, 8
    rep stosq
    mov qword [rsp + 32], 700
    lea rax, [scroll_font]
    mov qword [rsp + 104], rax
    mov ecx, -SCROLL_H
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call CreateFontA
    add rsp, 128
    mov rcx, qword [mem_dc]
    mov rdx, rax
    call SelectObject
    mov rcx, qword [mem_dc]
    mov edx, 0x0040E060
    call SetTextColor

    mov rcx, qword [mem_dc]
    lea rdx, [scroll_text]
    mov r8d, scroll_len
    lea r9, [rsp + 296]
    call GetTextExtentPoint32A
    mov eax, dword [rsp + 296]
    mov dword [scroll_w], eax

    call BuildLogo
    call MakeMask
    call InitField

    mov eax, dword [box_x0]
    mov dword [x_pos], eax
    mov dword [y_pos], 60
    mov dword [x_vel], 1
    mov dword [y_vel], 1
    mov dword [scroll_x], SCR_W

    mov rcx, qword [window_handle]
    mov edx, 1
    mov r8d, TIMER_MS
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

.fail:
    mov eax, 1
    jmp .return
.quit:
    xor eax, eax
.return:
    add rsp, 320
    pop rdi
    pop r12
    pop rbp
    ret

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
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
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
    mov rcx, qword [rsp + 80]
    call DestroyWindow
.zero:
    xor eax, eax
    jmp .done

.drag:
    call ReleaseCapture
    mov rcx, qword [rsp + 80]
    mov edx, WM_NCLBUTTONDOWN
    mov r8d, HTCAPTION
    xor r9d, r9d
    call SendMessageA
    xor eax, eax
    jmp .done

.destroy:
    xor ecx, ecx
    call PostQuitMessage
    xor eax, eax
    jmp .done

; ------------------------------------------------------------------ update --
.frame:
    inc dword [frame_counter]
    mov rax, qword [mem_dc]
    mov qword [rsp + 88], rax

    mov eax, dword [scroll_x]
    sub eax, SCROLL_SPEED
    mov ecx, dword [scroll_w]
    neg ecx
    cmp eax, ecx
    jg .scroll_ok
    mov eax, SCR_W
.scroll_ok:
    mov dword [scroll_x], eax

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

    lea r13, [rain_y]                   ; drops fall in 1/64 of a block row
    lea r14, [rain_v]
    xor r12d, r12d
.rain_step:
    mov eax, dword [r13 + r12 * 4]
    add eax, dword [r14 + r12 * 4]
    cmp eax, (GLYPH_ROWS + RAIN_TRAIL) * 64
    jl .rain_store
    call NextRand
    and eax, 15
    add eax, 3
    mov dword [r14 + r12 * 4], eax
    xor eax, eax
.rain_store:
    mov dword [r13 + r12 * 4], eax
    inc r12d
    cmp r12d, LOGO_COLS
    jb .rain_step

    lea r13, [stars_x]
    lea r14, [stars_y]
    lea r15, [stars_z]
    xor r12d, r12d
.star_step:
    call SyncTrail
    mov eax, dword [r15 + r12 * 4]
    sub eax, STAR_SPEED
    mov dword [r15 + r12 * 4], eax
    cmp eax, STAR_NEAR
    jle .star_reset

    call ProjectStar
    lea rcx, [stars_sx]
    mov eax, dword [rcx + r12 * 4]
    cmp eax, SCR_W
    jae .star_reset                     ; unsigned: catches negatives too
    lea rcx, [stars_sy]
    mov eax, dword [rcx + r12 * 4]
    cmp eax, SCR_H
    jb .star_next
.star_reset:
    call ResetStar
    call ProjectStar
    call SyncTrail
.star_next:
    inc r12d
    cmp r12d, STARS
    jb .star_step

; ------------------------------------------------------------------ render --
    mov r8, qword [pixels]              ; clear the frame, two pixels at a time
    mov ecx, SCR_W * SCR_H / 2
.clear:
    dec ecx
    mov qword [r8 + rcx * 8], 0
    jnz .clear

    mov rcx, qword [rsp + 88]
    mov edx, dword [scroll_x]
    mov r8d, SCROLL_Y
    lea r9, [scroll_text]
    mov dword [rsp + 32], scroll_len
    call TextOutA

    ; GDI batches its work, so flush before writing to the bits by hand
    call GdiFlush

    lea r15, [stars_z]
    xor r12d, r12d
.star_draw:
    mov eax, dword [r15 + r12 * 4]
    shr eax, 2
    mov edx, 255
    sub edx, eax                        ; brightness from depth
    cmp edx, 40
    jge .lum_ok
    mov edx, 40
.lum_ok:
    mov eax, edx                        ; white stars: R = G = B
    shl eax, 8
    or edx, eax
    shl eax, 8
    or edx, eax
    mov dword [rsp + 128], edx

    lea rcx, [stars_px]
    mov eax, dword [rcx + r12 * 4]
    mov dword [rsp + 120], eax
    lea rcx, [stars_py]
    mov eax, dword [rcx + r12 * 4]
    mov dword [rsp + 124], eax
    lea rcx, [stars_sx]
    mov r13d, dword [rcx + r12 * 4]
    lea rcx, [stars_sy]
    mov r14d, dword [rcx + r12 * 4]

    mov ecx, r13d                       ; head, then tail
    mov edx, r14d
    mov r8d, dword [rsp + 120]
    mov r9d, dword [rsp + 124]
    mov eax, dword [rsp + 128]
    call DrawTrail

    cmp dword [r15 + r12 * 4], STAR_FAT ; the closest ones are drawn twice
    jg .star_thin
    lea ecx, [r13 + 1]
    mov edx, r14d
    mov r8d, dword [rsp + 120]
    inc r8d
    mov r9d, dword [rsp + 124]
    mov eax, dword [rsp + 128]
    call DrawTrail
.star_thin:
    inc r12d
    cmp r12d, STARS
    jb .star_draw

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
    imul ecx, ecx, SCALE
    add ecx, dword [x_pos]
    mov edx, r14d
    imul edx, edx, SCALE
    add edx, dword [y_pos]
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
    xor r12d, r12d
.rain_col:
    lea rax, [rain_y]
    mov eax, dword [rax + r12 * 4]
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
    imul edx, edx, SCALE
    add edx, dword [y_pos]
    mov ecx, r12d
    imul ecx, ecx, SCALE
    add ecx, dword [x_pos]
    lea rax, [level_col]
    mov r8d, dword [rax + r13 * 4]
    call DrawBlock
.rain_next:
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
    imul ecx, ecx, SCALE
    add ecx, dword [x_pos]
    mov edx, r14d
    imul edx, edx, SCALE
    add edx, dword [y_pos]
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
    mov rax, qword [rsp + 88]
    mov qword [rsp + 32], rax
    lea rax, [ulw_src]
    mov qword [rsp + 40], rax
    mov qword [rsp + 48], 0
    lea rax, [ulw_blend]
    mov qword [rsp + 56], rax
    mov qword [rsp + 64], ULW_ALPHA
    call UpdateLayeredWindow
    xor eax, eax

.done:
    add rsp, 176
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret
