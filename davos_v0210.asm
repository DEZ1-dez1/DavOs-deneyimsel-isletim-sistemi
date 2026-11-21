; DavOS - TEK DOSYA: stage1 + stage2 ayni davos.img icinde
; Surum: MAJOR.MINOR.PATCH (asagidaki VER_* sabitleri)
;   MAJOR: uyumsuz/buyuk degisiklik (ornek: 32 bit protected mode'a gecis)
;   MINOR: geriye uyumlu yeni ozellik (yeni komut, dosya sistemi, heap)
;   PATCH: sadece hata duzeltme / kucuk iyilestirme
; Derleme: nasm -f bin davos_v0210.asm -o davos.img
;          truncate -s 1440k davos.img
; Limbo'da davos.img'i Floppy (FDA) olarak sec.
;
; Akis: boot bilgileri -> 3 sn bekle -> ekran temizle -> local_user$ CLI

[bits 16]
[org 0x7C00]

VER_MAJOR    equ 0
VER_MINOR    equ 21
VER_PATCH    equ 0
BITMAP_SEG   equ 0x2000          ; fiziksel 0x20000
BITMAP_BYTES equ 16384
MAXPAGES     equ 131072          ; 512 MB / 4 KB
S2_SECT      equ 60             ; stage2 = 60 sektor (30 KB)
E820BUF      equ 0xF800
CMDBUF       equ 0xF900          ; komut satiri tamponu (64 bayt)
HEAP_FIRST   equ 16              ; heap: 0x10000'dan
HEAP_END     equ 0x9F            ; heap: 0x9F000'a kadar (haric)
ERR_UNKNOWN  equ 1
ERR_USAGE    equ 2
ERR_NOFILE   equ 3
ERR_NOMEM    equ 4
ERR_DIRFULL  equ 5
ERR_BADPAGE  equ 6
ERR_SYNTAX   equ 7
ERR_DIV0     equ 8
ERR_NOTEMPTY equ 9
ERR_ISDIR    equ 10
ERR_NOTDIR   equ 11
ERR_EXISTS   equ 12
ERR_OVERFLOW equ 13
ERR_DISK     equ 14
ERR_SAMECOLOR equ 15
ERR_MAX      equ 15
SET_LBA      equ 2100            ; kullanici ayarlari (1 sektor)
FS_LBA       equ 64              ; kalici dosya sistemi: disk sektoru 32'den
FSBUF        equ 0xFA00          ; 512 bayt baslik tamponu

; =====================================================
; STAGE 1 (boot sector, 512 bayt)
; =====================================================
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [bootdrv], dl

    mov word [spt], 18           ; geometri: BIOS'tan oku, olmazsa disket varsay
    mov word [heads], 2
    mov ah, 0x08
    int 0x13
    jc .geo
    mov al, cl
    and ax, 0x003F
    jz .geo
    mov [spt], ax
    mov al, dh
    xor ah, ah
    inc ax
    mov [heads], ax
.geo:
    xor ax, ax
    mov es, ax                   ; AH=08 ES'yi bozabilir
    mov ax, [spt]
    mul word [heads]
    mov [sph], ax                ; sektor/silindir
    mov word [lba], 1
    mov word [left], S2_SECT
    mov word [dst], 0x7E00

.rd:
    mov ax, [lba]                ; LBA -> CHS
    xor dx, dx
    div word [sph]
    mov ch, al
    mov cl, ah
    shl cl, 6
    mov ax, dx
    xor dx, dx
    div word [spt]
    mov dh, al
    inc dl
    or cl, dl
    mov dl, [bootdrv]
    mov [chs_cx], cx
    mov [chs_dx], dx
    mov byte [tries], 3
.try:
    mov cx, [chs_cx]
    mov dx, [chs_dx]
    mov bx, [dst]
    mov ax, 0x0201
    int 0x13
    jnc .ok
    xor ax, ax
    mov dl, [bootdrv]
    int 0x13
    dec byte [tries]
    jnz .try
    jmp disk_error
.ok:
    add word [dst], 512
    inc word [lba]
    dec word [left]
    jnz .rd
    jmp stage2_start

disk_error:
    mov si, err_msg
.p: lodsb
    test al, al
    jz .h
    mov ah, 0x0E
    int 0x10
    jmp .p
.h: cli
    hlt
    jmp .h

bootdrv db 0
tries   db 0
spt     dw 0
heads   dw 0
sph     dw 0
lba     dw 0
left    dw 0
dst     dw 0
chs_cx  dw 0
chs_dx  dw 0
err_msg db 'Disk error', 0

times 510 - ($ - $$) db 0
dw 0xAA55

; =====================================================
; STAGE 2 (0x7E00)
; =====================================================
stage2_start:
    mov ax, 0x0003
    int 0x10
    mov ax, 0x1100               ; ozel karakterler: 0x80-0x86
    mov bx, 0x1000               ; BH=16 bayt/karakter, BL=blok 0
    mov cx, 14
    mov dx, 0x80
    mov bp, custom_font
    int 0x10
    mov ax, 0x1003               ; yanip sonme kapali: 16 arka plan rengi
    xor bx, bx
    int 0x10
    mov ax, 0xB800
    mov gs, ax
    cld
    call get_ticks
    mov [boot_ticks], eax        ; uptime icin baslangic

    mov byte [attr], 0x0B
    mov si, msg_boot
    call print

    ; ---- bitmap'i 0xFF ile doldur
    mov ax, BITMAP_SEG
    mov es, ax
    xor di, di
    mov cx, BITMAP_BYTES
    mov al, 0xFF
    rep stosb
    xor ax, ax
    mov es, ax

    ; ---- E820
    xor ebx, ebx
.e: mov di, E820BUF
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    int 0x15
    jc .edone
    cmp eax, 0x534D4150
    jne .edone
    call handle_entry
    test ebx, ebx
    jnz .e
.edone:

    ; ---- Kernel icin sayfalari kilitle
    xor edx, edx
    mov esi, HEAP_FIRST          ; 0x0000 - 0xBFFF: boot, stage2, tamponlar
    call lock_range
    mov eax, [used_pages]
    mov [pg_low], eax
    mov edx, 0x20
    mov esi, 4
    call lock_range
    mov eax, [used_pages]
    sub eax, [pg_low]
    mov [pg_map], eax

    call fs_load                 ; diskteki dosya sistemini geri yukle
    call show_ram

    mov byte [attr], 0x07
    mov si, msg_lock
    call print

    mov byte [attr], 0x07
    mov eax, [pg_low]
    call print_dec
    mov si, msg_arrow
    call print
    mov eax, [pg_map]
    call print_dec
    mov si, msg_arrow
    call print
    mov eax, [pg_kernel]
    call print_dec
    mov si, msg_arrow
    call print
    mov eax, [pg_heap]
    call print_dec

    call wait_3s
    jmp startup                  ; ilk acilis sihirbazi / kilit ekrani / masaustu

; =====================================================
; CLI (konsol): exit ile masaustune doner
; =====================================================
shell_run:
    mov byte [ui_exit], 0
.l: mov byte [attr], 0x0A
    mov si, msg_prompt
    call print
    cmp byte [cwd_path + 1], 0
    je .nop
    mov byte [attr], 0x0B
    mov al, ':'
    call putc
    mov si, cwd_path
    call print
.nop:
    mov byte [attr], 0x0A
    mov si, msg_dollar
    call print
    mov byte [attr], 0x07
    call read_line
    call execute
    cmp byte [ui_exit], 0
    je .l
    ret

; ---- Satir oku (CMDBUF'a, 0 ile biter)
read_line:
    push ax
    push bx
    push cx
    xor cx, cx
.k: call mouse_cursor_update     ; beklerken fare imleci gorunur
    call set_hwcursor
    call wait_key
    call mouse_hide              ; yazarken gizle
    cmp ah, 0xFF                 ; pencere kapatma tiklamasi
    je .close
    cmp al, 13
    je .enter
    cmp al, 8
    je .bs
    cmp al, 32
    jb .k
    cmp al, 126
    ja .k
    cmp al, '`'                  ; ` = sembol paletini ac
    jne .put
    call palette_pick
    jc .k
.put:
    cmp cx, 63
    jae .k
    mov bx, CMDBUF
    add bx, cx
    mov [bx], al
    inc cx
    call putc
    jmp .k
.bs:
    test cx, cx
    jz .k
    dec cx
    call cursor_back
    jmp .k
.enter:
    mov bx, CMDBUF
    add bx, cx
    mov byte [bx], 0
    call expand_symbols
    mov al, 10
    call putc
    pop cx
    pop bx
    pop ax
    ret
.close:
    mov byte [CMDBUF], 0
    mov byte [ui_exit], 1
    pop cx
    pop bx
    pop ax
    ret

wait_key:                        ; AL = karakter, AH = tarama kodu; AX = 0xFF00: pencere kapatildi
.w: mov ah, 1
    int 0x16
    jnz .got
    call ui_tick                 ; beklerken fare ve saat guncellenir
    cmp byte [ui_close_req], 0
    jne .cl
    cmp byte [clk_pending], 0
    je .w
    mov byte [clk_pending], 0
    mov ax, 0xFE00               ; AX = 0xFE00: fare tiklamasi ([clk_row], [clk_col])
    ret
.cl:
    mov byte [ui_close_req], 0
    mov ax, 0xFF00
    ret
.got:
    xor ah, ah
    int 0x16
    ret

ui_tick:
    cmp byte [ui_active], 0
    je .r
    call ui_clock
    call mouse_poll
    call long_press_check
.r: ret

; Paleti ac, bir tusa basilmasini bekle. AL = secilen sembol, CF=1 iptal
palette_pick:
    call show_palette
    mov byte [cur_freeze], 1
    call wait_key
    cmp al, 'a'
    jb .u
    cmp al, 'z'
    ja .u
    sub al, 32                   ; kucuk harf = buyuk harf
.u: xor bx, bx
.s: cmp bx, 36
    jae .cancel
    cmp al, [pal_keys + bx]
    je .found
    inc bx
    jmp .s
.found:
    mov al, [pal_syms + bx]
    call hide_palette
    mov byte [cur_freeze], 0
    clc
    ret
.cancel:
    call hide_palette
    mov byte [cur_freeze], 0
    stc
    ret

show_palette:
    pusha
    mov bx, [cursor]             ; imlec ust yarida ise palet altta, degilse ustte
    xor ax, ax
    cmp bx, 12 * 160
    jae .set
    mov ax, 22 * 160
.set:
    mov [pal_off], ax
    push ds
    push es
    mov si, ax                   ; ekran satirlarini kaydet
    mov ax, 0xB800
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov di, pal_save
    mov cx, 160
    cld
    rep movsw
    pop es
    pop ds
    mov di, [pal_off]            ; mavi zemin
    mov cx, 160
    mov ax, 0x1F20
.f: mov [gs:di], ax
    add di, 2
    loop .f
    xor bx, bx
.d: cmp bx, 36
    jae .done
    mov di, bx
    shl di, 2
    add di, 6
    add di, [pal_off]
    mov al, [pal_keys + bx]
    mov ah, 0x1E
    mov [gs:di], ax
    mov al, [pal_syms + bx]
    mov ah, 0x1F
    mov [gs:di + 160], ax
    inc bx
    jmp .d
.done:
    popa
    ret

hide_palette:
    pusha
    push es
    mov ax, 0xB800
    mov es, ax
    mov si, pal_save
    mov di, [pal_off]
    mov cx, 160
    cld
    rep movsw
    pop es
    popa
    ret

; CMDBUF icindeki :isim: dizilerini ozel sembol baytina cevir
expand_symbols:
    pushad
    mov si, CMDBUF
    mov di, CMDBUF
.l: mov al, [si]
    test al, al
    jz .d
    cmp al, ':'
    je .open
    cmp al, ';'                  ; Limbo ':' yerine ';' gonderiyor, ikisi de olur
    jne .copy
.open:
    mov bp, si
    mov bx, sym_table
.try:
    cmp byte [bx], 0
    je .nomatch
    mov dx, bx
    mov si, bp
    inc si
.cmp:
    mov al, [bx]
    test al, al
    jz .nameend
    cmp al, [si]
    jne .nxt
    inc bx
    inc si
    jmp .cmp
.nameend:
    cmp byte [si], ':'
    je .close
    cmp byte [si], ';'
    jne .nxt
.close:
    mov al, [bx + 1]
    inc si
    mov [di], al
    inc di
    jmp .l
.nxt:
    mov bx, dx
.sk:
    cmp byte [bx], 0
    je .sk2
    inc bx
    jmp .sk
.sk2:
    add bx, 2
    jmp .try
.nomatch:
    mov si, bp
.copy:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    jmp .l
.d: mov byte [di], 0
    popad
    ret

; ---- Komutu calistir (ilk kelime = komut, kalani = arguman)
execute:
    mov si, CMDBUF
    cmp byte [si], 0
    je .ret
.sp:
    cmp byte [si], 0
    je .got
    cmp byte [si], ' '
    je .split
    inc si
    jmp .sp
.split:
    mov byte [si], 0
    inc si
.skip:
    cmp byte [si], ' '
    jne .got
    inc si
    jmp .skip
.got:
    mov [argptr], si
    mov si, CMDBUF               ; komut kelimesini kucuk harfe cevir (Help = help)
.lc:
    mov al, [si]
    test al, al
    jz .lcd
    cmp al, 'A'
    jb .lcn
    cmp al, 'Z'
    ja .lcn
    add al, 32
    mov [si], al
.lcn:
    inc si
    jmp .lc
.lcd:
    mov si, CMDBUF
    mov bx, cmd_table
.l: mov di, [bx]
    test di, di
    jz .unk
    call streq
    je .run
    add bx, 4
    jmp .l
.run:
    call word [bx + 2]
    xor ax, ax
    mov es, ax
.ret:
    ret
.unk:
    mov al, ERR_UNKNOWN
    call error
    mov si, CMDBUF
    call print
    mov si, msg_unk2
    call print
    ret

; SI ve DI stringleri esit mi? ZF=1 ise esit
streq:
    push si
    push di
    push ax
.l: mov al, [si]
    cmp al, [di]
    jne .n
    test al, al
    jz .eq
    inc si
    inc di
    jmp .l
.eq:
    xor ax, ax                   ; ZF=1
    jmp .end
.n: or al, 1                     ; ZF=0
.end:
    pop ax
    pop di
    pop si
    ret

; ---- Komutlar
cmd_help:
    mov si, help_table
print_table:                     ; SI = tablo (etiket,0,aciklama,0 ... 0)
.l: cmp byte [si], 0
    je .d
    mov byte [attr], 0x0B
    call print
    mov byte [attr], 0x07
    call print
    jmp .l
.d: ret

cmd_clear:
    call clear_screen
    ret

cmd_ram:
    call show_ram
    ret

cmd_ver:
    mov byte [attr], 0x07
    call print_ver
    mov si, msg_ver_tail
    call print
    ret

print_ver:                       ; "DavOS v0.5.0"
    push eax
    push si
    mov si, msg_ver_pre
    call print
    mov eax, VER_MAJOR
    call print_dec
    mov al, '.'
    call putc
    mov eax, VER_MINOR
    call print_dec
    mov al, '.'
    call putc
    mov eax, VER_PATCH
    call print_dec
    pop si
    pop eax
    ret

cmd_sym:                         ; ozel sembol listesi
    mov si, sym_table
.l: cmp byte [si], 0
    je .d
    mov byte [attr], 0x0B
    mov al, ':'
    call putc
    call print
    mov al, ':'
    call putc
    mov byte [attr], 0x07
    mov al, ' '
    call putc
    mov al, [si]
    inc si
    call putc
    mov al, 10
    call putc
    jmp .l
.d: ret

cmd_reboot:
    mov al, 0xFE
    out 0x64, al
    jmp 0xFFFF:0x0000

cmd_neofetch:
    push bx
    push bp
    mov bp, logo_table
    mov bx, nf_text
    call logo
    call nf_static               ; local_user@DavOS
    call logo
    call nf_static               ; ----
    call logo
    call nf_static               ; OS
    call logo
    call nf_label                ; Host
    call print_host
    call nf_nl
    call logo
    call nf_label                ; Kernel
    call print_ver
    call nf_nl
    call logo
    call nf_label                ; Uptime
    call print_uptime
    mov si, msg_secs
    call print
    call logo
    call nf_static               ; Shell
    call logo
    call nf_static               ; Resolution
    call logo
    call nf_static               ; Terminal
    call logo
    call nf_label                ; CPU
    call print_cpu
    call nf_nl
    call logo
    call nf_label                ; Memory
    call print_mem
    call nf_nl
    call logo                    ; bos satir
    call nf_nl
    call logo
    call print_blocks            ; renk kutulari
    call nf_nl
    mov byte [attr], 0x07
    pop bp
    pop bx
    ret

logo:                            ; BP'deki logo satiri: D cyan, yildiz (blok karakterler) sari
    push si
    push ax
    mov si, bp
.l: lodsb
    test al, al
    jz .d
    mov byte [attr], 0x0B
    cmp al, 0xDB
    jb .p
    cmp al, 0xDF
    ja .p
    mov byte [attr], 0x0E
.p: call putc
    jmp .l
.d: mov bp, si
    pop ax
    pop si
    ret

nf_static:                       ; BX: etiket (cyan) + deger (beyaz)
    push si
    mov byte [attr], 0x0B
    mov si, bx
    call print
    mov byte [attr], 0x07
    call print
    mov bx, si
    pop si
    ret

nf_label:                        ; BX: sadece etiket (cyan)
    push si
    mov byte [attr], 0x0B
    mov si, bx
    call print
    mov bx, si
    mov byte [attr], 0x07
    pop si
    ret

nf_nl:
    push ax
    mov al, 10
    call putc
    pop ax
    ret

print_blocks:
    push ax
    push si
    mov di, block_attrs
.l: mov al, [di]
    test al, al
    jz .d
    mov [attr], al
    mov si, msg_block
    call print
    inc di
    jmp .l
.d: mov byte [attr], 0x07
    pop si
    pop ax
    ret

get_ticks:                       ; EAX = BIOS tick sayaci (18.2/sn)
    push ecx
    push edx
    xor ax, ax
    int 0x1A
    movzx eax, cx
    shl eax, 16
    movzx edx, dx
    or eax, edx
    pop edx
    pop ecx
    ret

has_cpuid:                       ; ZF=0 ise CPUID var
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    test eax, 0x200000
    ret

print_host:
    pushad
    call has_cpuid
    jz .unk
    mov eax, 1
    cpuid
    test ecx, 0x80000000         ; hypervisor biti
    jz .unk
    mov eax, 0x40000000
    cpuid
    mov [hv_buf], ebx
    mov [hv_buf + 4], ecx
    mov [hv_buf + 8], edx
    mov si, hv_buf
    call print
    jmp .d
.unk:
    mov si, msg_unknown
    call print
.d: popad
    ret

print_cpu:
    pushad
    call has_cpuid
    jz .unk
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .vendor
    mov di, cpu_buf
    mov esi, 0x80000002
.b: mov eax, esi
    cpuid
    mov [di], eax
    mov [di + 4], ebx
    mov [di + 8], ecx
    mov [di + 12], edx
    add di, 16
    inc esi
    cmp esi, 0x80000004
    jbe .b
    mov si, cpu_buf
.sk:
    cmp byte [si], ' '
    jne .pr
    inc si
    jmp .sk
.pr:
    call print
    jmp .d
.vendor:
    xor eax, eax
    cpuid
    mov [hv_buf], ebx
    mov [hv_buf + 4], edx
    mov [hv_buf + 8], ecx
    mov si, hv_buf
    call print
    jmp .d
.unk:
    mov si, msg_unknown
    call print
.d: popad
    ret

print_uptime:                    ; boot'tan beri saniye (gercek tick farki)
    pushad
    call get_ticks
    sub eax, [boot_ticks]
    mov ecx, 10
    mul ecx
    mov ecx, 182
    xor edx, edx
    div ecx
    call print_dec
    popad
    ret

print_mem:                       ; kullanilan KiB / toplam MiB (bitmap'ten)
    pushad
    mov eax, [used_pages]
    shl eax, 2
    call print_dec
    mov si, msg_kib
    call print
    call count_free
    add eax, [used_pages]
    shl eax, 2
    shr eax, 10
    call print_dec
    mov si, msg_mib
    call print
    popad
    ret

; =====================================================
; Heap (sayfa ayirici) + RAM dosya sistemi
; =====================================================
cmd_echo:
    mov byte [attr], 0x07
    mov si, [argptr]
    call print
    mov al, 10
    call putc
    ret

perr:                            ; SI = hata metni (kirmizi)
    mov byte [attr], 0x0C
    call print
    mov byte [attr], 0x07
    ret

; EAX = ayrilan sayfanin fiziksel adresi, CF=1 ise heap dolu
alloc_page:
    push ebx
    push ecx
    push edx
    push es
    mov ax, BITMAP_SEG
    mov es, ax
    mov edx, HEAP_FIRST
.l: cmp edx, HEAP_END
    jae .fail
    mov ebx, edx
    shr ebx, 3
    mov cl, dl
    and cl, 7
    mov al, 1
    shl al, cl
    test [es:bx], al
    jz .got
    inc edx
    jmp .l
.got:
    or [es:bx], al
    inc dword [used_pages]
    inc dword [pg_heap]
    mov eax, edx
    shl eax, 12
    clc
    jmp .d
.fail:
    stc
.d: pop es
    pop edx
    pop ecx
    pop ebx
    ret

; EAX = sayfa fiziksel adresi, CF=1 ise gecersiz
free_page:
    push ebx
    push ecx
    push edx
    push es
    mov edx, eax
    test edx, 0xFFF
    jnz .bad
    shr edx, 12
    cmp edx, HEAP_FIRST
    jb .bad
    cmp edx, HEAP_END
    jae .bad
    mov ax, BITMAP_SEG
    mov es, ax
    mov ebx, edx
    shr ebx, 3
    mov cl, dl
    and cl, 7
    mov al, 1
    shl al, cl
    test [es:bx], al
    jz .bad
    not al
    and [es:bx], al
    dec dword [used_pages]
    dec dword [pg_heap]
    clc
    jmp .d
.bad:
    stc
.d: pop es
    pop edx
    pop ecx
    pop ebx
    ret

; argumandan (decimal) sayi oku -> EAX, CF=1 ise sayi yok
atoi:
    push ecx
    push edx
    push si
    mov si, [argptr]
    xor eax, eax
    xor ecx, ecx
.l: movzx edx, byte [si]
    sub dl, '0'
    cmp dl, 9
    ja .end
    imul eax, eax, 10
    add eax, edx
    inc ecx
    inc si
    jmp .l
.end:
    test ecx, ecx
    jnz .ok
    stc
    jmp .d
.ok:
    clc
.d: pop si
    pop edx
    pop ecx
    ret

cmd_alloc:
    call alloc_page
    jc .fail
    shr eax, 12
    mov bx, ax
    mov byte [umap + bx], 1
    push eax
    mov byte [attr], 0x07
    mov si, msg_alloc
    call print
    pop eax
    call print_dec
    mov si, msg_heapis
    call print
    mov eax, [pg_heap]
    call print_dec
    mov al, 10
    call putc
    ret
.fail:
    mov al, ERR_NOMEM
    call error
    ret

cmd_free:
    call atoi
    jc .usage
    cmp eax, HEAP_END
    jae .bad
    mov bx, ax
    cmp byte [umap + bx], 1
    jne .bad
    shl eax, 12
    call free_page
    jc .bad
    mov byte [umap + bx], 0
    mov byte [attr], 0x07
    mov si, msg_freed
    call print
    ret
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_free
    call print
    ret
.bad:
    mov al, ERR_BADPAGE
    call error
    ret

cmd_heap:
    mov byte [attr], 0x07
    mov si, msg_heapinfo
    call print
    mov eax, [pg_heap]
    call print_dec
    mov si, msg_sayfa
    call print
    mov eax, [pg_heap]
    shl eax, 2
    call print_kb
    ret

; ---- Dosya sistemi: dizin = 1 heap sayfasi (64 giris x 16 bayt)
; giris: ad[12] | boyut dw | veri segmenti dw   (her dosya = 1 heap sayfasi)
fs_ensure:                       ; dizin sayfasini yoksa olustur, CF=1 hata
    cmp word [fs_dir_seg], 0
    jne .ok
    call alloc_page
    jc .ret
    shr eax, 4
    mov [fs_dir_seg], ax
    mov [cur_dir_seg], ax
    push es
    push di
    push cx
    mov es, ax
    xor di, di
    mov cx, 2048
    xor ax, ax
    cld
    rep stosw
    mov ax, [fs_dir_seg]         ; kokun '..' girisi kendisi
    mov byte [es:0], '.'
    mov byte [es:1], '.'
    mov [es:30], ax
    mov word [es:28], 0xFFFF
    pop cx
    pop di
    pop es
.ok:
    clc
.ret:
    ret

; [namebuf] dosyayi ara: CF=0 bulundu (ES:DI = giris), CF=1 yok
fs_find:
    push ax
    push cx
    push si
    mov ax, [cur_dir_seg]
    mov es, ax
    xor di, di
    mov cx, 128
.l: cmp byte [es:di], 0
    je .next
    push di
    mov si, namebuf
.c: mov al, [si]
    cmp al, [es:di]
    jne .ne
    test al, al
    jz .eq
    inc si
    inc di
    jmp .c
.eq:
    pop di
    clc
    jmp .done
.ne:
    pop di
.next:
    add di, 32
    loop .l
    stc
.done:
    pop si
    pop cx
    pop ax
    ret

fs_slot:                         ; bos giris: CF=0 ES:DI, CF=1 dizin dolu
    push ax
    push cx
    mov ax, [cur_dir_seg]
    mov es, ax
    xor di, di
    mov cx, 128
.l: cmp byte [es:di], 0
    je .f
    add di, 32
    loop .l
    stc
    jmp .d
.f: clc
.d: pop cx
    pop ax
    ret

; SI = arguman -> [namebuf]=ilk kelime, SI = geri kalan, CF=1 ad yok
parse_name:
    push ax
    push cx
    push di
    mov di, namebuf
    xor cx, cx
.c: mov al, [si]
    test al, al
    jz .end
    cmp al, ' '
    je .end
    cmp cx, 27
    jae .sk
    mov [di], al
    inc di
    inc cx
.sk:
    inc si
    jmp .c
.end:
    mov byte [di], 0
.sp:
    cmp byte [si], ' '
    jne .d
    inc si
    jmp .sp
.d: test cx, cx
    jnz .ok
    stc
    jmp .r
.ok:
    clc
.r: pop di
    pop cx
    pop ax
    ret

cmd_write:
    mov si, [argptr]
    call parse_name
    jc .usage
    cmp byte [namebuf], '.'
    je .dot
    mov [restptr], si
    call fs_ensure
    jc .nomem
    call fs_find
    jc .new
    cmp word [es:di + 28], 0xFFFF
    je .isdir
    jmp .have
.new:
    call fs_slot
    jc .full
    call alloc_page
    jc .nomem
    shr eax, 4
    mov [es:di + 30], ax
    mov si, namebuf
    push di
    mov cx, 28
.cn:
    lodsb
    mov [es:di], al
    inc di
    loop .cn
    pop di
.have:
    mov [tmpoff], di
    mov ax, [es:di + 30]
    mov es, ax
    mov si, [restptr]
    xor di, di
    xor cx, cx
.cp:
    lodsb
    test al, al
    jz .cpd
    cmp cx, 4095
    jae .cpd
    mov [es:di], al
    inc di
    inc cx
    jmp .cp
.cpd:
    mov ax, [cur_dir_seg]
    mov es, ax
    mov di, [tmpoff]
    mov [es:di + 28], cx
    mov byte [attr], 0x07
    mov si, msg_written
    call print
    jmp fs_commit
.dot:
    mov al, ERR_USAGE
    call error
    mov si, msg_baddot
    call print
    ret
.isdir:
    mov al, ERR_ISDIR
    call error
    ret
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_write
    call print
    ret
.nomem:
    mov al, ERR_NOMEM
    call error
    ret
.full:
    mov al, ERR_DIRFULL
    call error
    ret

cmd_cat:
    mov si, [argptr]
    call parse_name
    jc .usage
    cmp word [fs_dir_seg], 0
    je .nf
    call fs_find
    jc .nf
    cmp word [es:di + 28], 0xFFFF
    je .isdir
    mov cx, [es:di + 28]
    mov ax, [es:di + 30]
    mov es, ax
    xor di, di
    mov byte [attr], 0x07
.l: test cx, cx
    jz .d
    mov al, [es:di]
    call putc
    inc di
    dec cx
    jmp .l
.d: mov al, 10
    call putc
    ret
.isdir:
    mov al, ERR_ISDIR
    call error
    ret
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_file
    call print
    ret
.nf:
    mov al, ERR_NOFILE
    call error
    ret

cmd_rm:
    mov si, [argptr]
    call parse_name
    jc .usage
    cmp byte [namebuf], '.'
    je .nf
    cmp word [fs_dir_seg], 0
    je .nf
    call fs_find
    jc .nf
    cmp word [es:di + 28], 0xFFFF
    je .dir
    movzx eax, word [es:di + 30]
    shl eax, 4
    call free_page
    mov byte [es:di], 0
    mov byte [attr], 0x07
    mov si, msg_removed
    call print
    jmp fs_commit
.dir:
    mov [tmpoff], di
    mov ax, [es:di + 30]
    mov [tmpseg], ax
    mov es, ax
    mov di, 32
    mov cx, 127
.chk:
    cmp byte [es:di], 0
    jne .ne
    add di, 32
    loop .chk
    movzx eax, word [tmpseg]
    shl eax, 4
    call free_page
    mov ax, [cur_dir_seg]
    mov es, ax
    mov di, [tmpoff]
    mov byte [es:di], 0
    mov byte [attr], 0x07
    mov si, msg_removed
    call print
    jmp fs_commit
.ne:
    mov al, ERR_NOTEMPTY
    call error
    ret
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_file
    call print
    ret
.nf:
    mov al, ERR_NOFILE
    call error
    ret

cmd_ls:
    cmp word [fs_dir_seg], 0
    je .none
    mov ax, [cur_dir_seg]
    mov es, ax
    xor di, di
    mov cx, 128
    mov dword [lscount], 0
.l: cmp byte [es:di], 0
    je .next
    cmp byte [es:di], '.'
    je .next
    inc dword [lscount]
    push cx
    push di
    mov byte [attr], 0x0B
    cmp word [es:di + 28], 0xFFFF
    jne .nm
    mov byte [attr], 0x0E
.nm:
    mov bx, 30
.n: mov al, [es:di]
    test al, al
    jz .pad
    call putc
    inc di
    dec bx
    jmp .n
.pad:
    test bx, bx
    jz .sz
    mov al, ' '
    call putc
    dec bx
    jmp .pad
.sz:
    pop di
    mov byte [attr], 0x07
    cmp word [es:di + 28], 0xFFFF
    jne .fsz
    mov si, msg_klasor
    call print
    jmp .szd
.fsz:
    movzx eax, word [es:di + 28]
    call print_dec
    mov si, msg_bayt
    call print
.szd:
    pop cx
.next:
    add di, 32
    dec cx
    jnz .l
    jmp .foot
.none:
    mov dword [lscount], 0
.foot:
    mov byte [attr], 0x07
    mov eax, [lscount]
    call print_dec
    mov si, msg_dosya
    call print
    ret

; ---- Klasorler
cmd_mkdir:
    mov si, [argptr]
    call parse_name
    jc .usage
    cmp byte [namebuf], '.'
    je .dot
    call fs_ensure
    jc .nomem
    call fs_find
    jnc .exists
    call fs_slot
    jc .full
    call alloc_page
    jc .nomem
    shr eax, 4
    mov [tmpseg], ax
    mov [es:di + 30], ax
    mov word [es:di + 28], 0xFFFF
    mov si, namebuf
    push di
    mov cx, 28
.cn:
    lodsb
    mov [es:di], al
    inc di
    loop .cn
    pop di
    mov ax, [cur_dir_seg]        ; ust klasor
    mov [tmpoff], ax
    mov ax, [tmpseg]
    mov es, ax
    xor di, di
    mov cx, 2048
    xor ax, ax
    cld
    rep stosw
    mov byte [es:0], '.'
    mov byte [es:1], '.'
    mov ax, [tmpoff]
    mov [es:30], ax
    mov word [es:28], 0xFFFF
    mov byte [attr], 0x07
    mov si, msg_created
    call print
    jmp fs_commit
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_mkdir
    call print
    ret
.dot:
    mov al, ERR_USAGE
    call error
    mov si, msg_baddot
    call print
    ret
.exists:
    mov al, ERR_EXISTS
    call error
    ret
.nomem:
    mov al, ERR_NOMEM
    call error
    ret
.full:
    mov al, ERR_DIRFULL
    call error
    ret

cmd_cd:
    mov si, [argptr]
    cmp byte [si], 0
    je .root
    call parse_name
    jc .root
    cmp byte [namebuf], '/'
    jne .norm
    cmp byte [namebuf + 1], 0
    je .root
.norm:
    cmp word [fs_dir_seg], 0
    je .nf
    call fs_find
    jc .nf
    cmp word [es:di + 28], 0xFFFF
    jne .notdir
    mov ax, [es:di + 30]
    mov [cur_dir_seg], ax
    cmp byte [namebuf], '.'
    jne .down
    cmp byte [namebuf + 1], '.'
    jne .down
    call path_up
    ret
.down:
    call path_down
    ret
.root:
    mov ax, [fs_dir_seg]
    mov [cur_dir_seg], ax
    mov byte [cwd_path + 1], 0
    ret
.nf:
    mov al, ERR_NOFILE
    call error
    ret
.notdir:
    mov al, ERR_NOTDIR
    call error
    ret

cmd_pwd:
    mov byte [attr], 0x0B
    mov si, cwd_path
    call print
    mov al, 10
    call putc
    ret

path_up:                         ; /a/b -> /a   ,  /a -> /
    push si
    mov si, cwd_path
.e: cmp byte [si], 0
    je .f
    inc si
    jmp .e
.f: dec si
    cmp si, cwd_path
    je .root
    cmp byte [si], '/'
    jne .f
    mov byte [si], 0
    pop si
    ret
.root:
    mov byte [cwd_path + 1], 0
    pop si
    ret

path_down:                       ; yola /namebuf ekle
    push si
    push di
    mov si, cwd_path
.e: cmp byte [si], 0
    je .f
    inc si
    jmp .e
.f: cmp si, cwd_path + 1
    je .name
    mov byte [si], '/'
    inc si
.name:
    mov di, namebuf
.c: cmp si, cwd_path + 62
    jae .end
    mov al, [di]
    mov [si], al
    inc si
    inc di
    test al, al
    jnz .c
    jmp .d
.end:
    mov byte [si], 0
.d: pop di
    pop si
    ret

; =====================================================
; Kalici dosya sistemi: sayfalar ayni fiziksel adreslerle diske yazilir
; Disk duzeni: sektor FS_LBA = baslik ('DAVF', sayfa sayisi, segment listesi)
;              ardindan her sayfa icin 8 sektor (4 KB)
; Acilista ayni adresler yeniden talep edilir, boylece isaretciler gecerli kalir.
; =====================================================
; EAX = fiziksel sayfa adresi, heap'te bos ise ayir: CF=1 gecersiz/dolu
claim_page:
    push ebx
    push ecx
    push edx
    push es
    mov edx, eax
    test edx, 0xFFF
    jnz .bad
    shr edx, 12
    cmp edx, HEAP_FIRST
    jb .bad
    cmp edx, HEAP_END
    jae .bad
    mov ax, BITMAP_SEG
    mov es, ax
    mov ebx, edx
    shr ebx, 3
    mov cl, dl
    and cl, 7
    mov al, 1
    shl al, cl
    test [es:bx], al
    jnz .bad
    or [es:bx], al
    inc dword [used_pages]
    inc dword [pg_heap]
    clc
    jmp .d
.bad:
    stc
.d: pop es
    pop edx
    pop ecx
    pop ebx
    ret

; AH = 2 oku / 3 yaz, ES:BX = tampon, [rw_lba] = sektor. CF=1 hata
rw_sector:
    pusha
    mov [rw_fn], ah
    mov [rw_buf], bx
    mov ax, [rw_lba]
    xor dx, dx
    div word [sph]
    mov ch, al
    mov cl, ah
    shl cl, 6
    mov ax, dx
    xor dx, dx
    div word [spt]
    mov dh, al
    inc dl
    or cl, dl
    mov dl, [bootdrv]
    mov [chs_cx], cx
    mov [chs_dx], dx
    mov byte [tries], 3
.t: mov cx, [chs_cx]
    mov dx, [chs_dx]
    mov bx, [rw_buf]
    mov ah, [rw_fn]
    mov al, 1
    int 0x13
    jnc .ok
    xor ax, ax
    mov dl, [bootdrv]
    int 0x13
    dec byte [tries]
    jnz .t
    popa
    stc
    ret
.ok:
    popa
    clc
    ret

; AH = 2/3, ES = sayfa segmenti, [rw_lba] = ilk sektor (8 sektor, [rw_lba] ilerler)
rw_page:
    push bx
    push cx
    xor bx, bx
    mov cx, 8
.l: call rw_sector
    jc .e
    inc word [rw_lba]
    add bx, 512
    loop .l
    clc
.e: pop cx
    pop bx
    ret

; Agaci gez, tum sayfalari diske yaz. CF=1 hata
fs_save:
    pusha
    push es
    cmp word [fs_dir_seg], 0
    je .ok
    mov word [pl_n], 1
    mov word [pl_i], 0
    mov ax, [fs_dir_seg]
    mov [pl_seg], ax
    mov byte [pl_typ], 1
.scan:
    mov bx, [pl_i]
    cmp bx, [pl_n]
    jae .hdr
    cmp byte [pl_typ + bx], 1
    jne .nxt
    shl bx, 1
    mov ax, [pl_seg + bx]
    mov es, ax
    xor di, di
    mov cx, 128
.e: cmp byte [es:di], 0
    je .en
    cmp byte [es:di], '.'
    je .en
    mov bx, [pl_n]
    cmp bx, 252
    jae .err
    mov ax, [es:di + 30]
    mov dl, 0
    cmp word [es:di + 28], 0xFFFF
    jne .t0
    mov dl, 1
.t0:
    mov [pl_typ + bx], dl
    shl bx, 1
    mov [pl_seg + bx], ax
    inc word [pl_n]
.en:
    add di, 32
    dec cx
    jnz .e
.nxt:
    inc word [pl_i]
    jmp .scan
.hdr:
    xor ax, ax
    mov es, ax
    mov di, FSBUF
    mov cx, 256
    cld
    rep stosw
    mov dword [FSBUF], 'DAVF'
    mov ax, [pl_n]
    mov [FSBUF + 4], ax
    mov si, pl_seg
    mov di, FSBUF + 6
    mov cx, [pl_n]
    rep movsw
    mov word [rw_lba], FS_LBA
    mov bx, FSBUF
    mov ah, 3
    call rw_sector
    jc .err
    mov word [rw_lba], FS_LBA + 1
    mov word [pl_i], 0
.wp:
    mov bx, [pl_i]
    cmp bx, [pl_n]
    jae .ok
    shl bx, 1
    mov ax, [pl_seg + bx]
    mov es, ax
    mov ah, 3
    call rw_page
    jc .err
    inc word [pl_i]
    jmp .wp
.ok:
    pop es
    popa
    clc
    ret
.err:
    pop es
    popa
    stc
    ret

fs_commit:                       ; degisiklikten sonra diske kaydet
    call fs_save
    jnc .ok
    mov al, ERR_DISK
    call error
.ok:
    ret

; Acilista: diskteki dosya sistemini ayni adreslere geri yukle
fs_load:
    pusha
    push es
    xor ax, ax
    mov es, ax
    mov word [rw_lba], FS_LBA
    mov bx, FSBUF
    mov ah, 2
    call rw_sector
    jc .none
    cmp dword [FSBUF], 'DAVF'
    jne .none
    mov cx, [FSBUF + 4]
    test cx, cx
    jz .none
    cmp cx, 252
    ja .none
    mov [pl_n], cx
    mov si, FSBUF + 6
    mov di, pl_seg
    cld
    rep movsw
    xor bx, bx
.cl:
    cmp bx, [pl_n]
    jae .rd
    mov si, bx
    shl si, 1
    movzx eax, word [pl_seg + si]
    shl eax, 4
    call claim_page
    jc .fail
    inc bx
    jmp .cl
.fail:
    mov [rel_n], bx
    jmp .rel
.rd:
    mov word [rw_lba], FS_LBA + 1
    xor bx, bx
.rp:
    cmp bx, [pl_n]
    jae .done
    mov si, bx
    shl si, 1
    mov ax, [pl_seg + si]
    mov es, ax
    mov ah, 2
    call rw_page
    jc .rerr
    inc bx
    jmp .rp
.rerr:
    mov ax, [pl_n]
    mov [rel_n], ax
.rel:
    xor bx, bx
.rl:
    cmp bx, [rel_n]
    jae .none
    mov si, bx
    shl si, 1
    movzx eax, word [pl_seg + si]
    shl eax, 4
    call free_page
    inc bx
    jmp .rl
.done:
    mov ax, [pl_seg]
    mov [fs_dir_seg], ax
    mov [cur_dir_seg], ax
.none:
    pop es
    popa
    ret

; =====================================================
; color: harf = arka plan (a-p), rakam = yazi rengi (0-9)
;   color a2   arka plan a, yazi 2     color a    sadece arka plan
;   color 5    sadece yazi             color reset  varsayilan (a7)
; a=siyah b=mavi c=yesil d=camgobegi e=kirmizi f=mor g=kahve h=acik gri
; i=koyu gri j=acik mavi k=acik yesil l=acik camgobegi m=acik kirmizi
; n=acik mor o=sari p=beyaz      0=siyah 1=mavi 2=yesil 3=camgobegi 4=kirmizi
; 5=mor 6=kahve 7=acik gri 8=koyu gri 9=acik mavi
; =====================================================
cmd_color:
    mov si, [argptr]
    cmp byte [si], 0
    je .legend
    mov di, s_reset
    call streq
    jne .parse
    mov byte [new_bg], 0
    mov byte [new_fg], 7
    jmp .set
.parse:
    mov byte [new_bg], 0xFF
    mov byte [new_fg], 0xFF
    mov al, [si]
    or al, 0x20
    cmp al, 'a'
    jb .dg
    cmp al, 'p'
    ja .bad
    sub al, 'a'
    mov [new_bg], al
    inc si
.dg:
    mov al, [si]
    sub al, '0'
    cmp al, 9
    ja .chk
    mov [new_fg], al
    inc si
.chk:
    cmp byte [si], 0
    jne .bad
    cmp byte [new_bg], 0xFF
    jne .set
    cmp byte [new_fg], 0xFF
    je .bad
.set:
    mov al, [bg_color]
    mov [old_bg], al
    mov al, [fg_color]
    mov [old_fg], al
    mov al, [new_bg]
    cmp al, 0xFF
    je .k1
    mov [bg_color], al
.k1:
    mov al, [new_fg]
    cmp al, 0xFF
    je .k2
    mov [fg_color], al
.k2:
    mov al, [bg_color]
    cmp al, [fg_color]
    jne .ok
    mov al, [old_bg]
    mov [bg_color], al
    mov al, [old_fg]
    mov [fg_color], al
    mov al, ERR_SAMECOLOR
    call error
    ret
.ok:
    call apply_colors
    ret
.bad:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_color
    call print
    ret
.legend:
    mov al, [bg_hi]
    mov [sv_bg], al
    mov al, [fg_color]
    mov [sv_fg], al
    mov byte [bg_hi], 0
    mov byte [fg_color], 7
    mov byte [attr], 0x07
    mov si, msg_col_bg
    call print
    xor bx, bx
.lb:
    cmp bx, 16
    jae .ld
    mov al, bl
    shl al, 4
    mov ah, 0x0F
    cmp bl, 7
    jb .tx
    xor ah, ah
.tx:
    or al, ah
    mov [attr], al
    mov al, 'a'
    add al, bl
    call putc
    mov byte [attr], 0x07
    mov al, ' '
    call putc
    inc bx
    jmp .lb
.ld:
    mov al, 10
    call putc
    mov al, [sv_bg]
    mov [bg_hi], al
    mov byte [attr], 0x07
    mov si, msg_col_fg
    call print
    xor bx, bx
.dl:
    cmp bx, 10
    jae .dd
    mov al, bl
    test al, al
    jnz .d1
    mov al, 0x70
.d1:
    mov [attr], al
    mov al, '0'
    add al, bl
    call putc
    mov byte [attr], 0x07
    mov al, ' '
    call putc
    inc bx
    jmp .dl
.dd:
    mov al, 10
    call putc
    mov al, [sv_fg]
    mov [fg_color], al
    mov byte [attr], 0x07
    mov si, msg_col_ex
    call print
    ret

apply_colors:                    ; goruntu alanindaki eski renkleri yenileriyle degistir
    pusha
    mov ax, [vp_y0]
    mov cx, 160
    mul cx
    mov di, [vp_x0]
    shl di, 1
    add di, ax
    mov bp, [vp_x1]
    sub bp, [vp_x0]
    inc bp
    mov dx, [vp_y1]
    sub dx, [vp_y0]
    inc dx
.row:
    push di
    mov cx, bp
.l: mov ax, [gs:di]
    mov bl, ah
    mov bh, bl
    shr bh, 4
    and bl, 0x0F
    cmp bh, [old_bg]
    jne .b
    mov bh, [bg_color]
.b: cmp bl, [old_fg]
    jne .f
    mov bl, [fg_color]
.f: shl bh, 4
    or bh, bl
    mov ah, bh
    mov [gs:di], ax
    add di, 2
    loop .l
    pop di
    add di, 160
    dec dx
    jnz .row
    mov al, [bg_color]
    shl al, 4
    mov [bg_hi], al
    or al, [fg_color]
    mov [scr_attr], al
    popa
    ret

; =====================================================
; XOX: xox (menu) | xox kolay | xox orta | xox zor | xox 2 (iki kisilik)
;   kolay = rastgele hamle
;   orta  = kazanabiliyorsa kazanir, rakibi engeller, aksi halde rastgele
;   zor   = minimax (yenilmez)
; =====================================================
cmd_xox:
    mov byte [xo_mode], 1
    mov byte [xo_lvl], 3
    mov si, [argptr]
    cmp byte [si], 0
    je .menu
    mov di, s_kolay
    call streq
    jne .a2
    mov byte [xo_lvl], 1
    jmp .new
.a2:
    mov di, s_orta
    call streq
    jne .a3
    mov byte [xo_lvl], 2
    jmp .new
.a3:
    mov di, s_zor
    call streq
    jne .a4
    jmp .new
.a4:
    cmp byte [si], '2'
    jne .menu
    mov byte [xo_mode], 2
    jmp .new
.menu:
    call clear_screen
    mov byte [attr], 0x0E
    mov si, msg_xo_menu
    call print
.mk:
    call wait_key
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit
    cmp al, 27
    je .quit
    cmp al, '1'
    jb .mk
    cmp al, '4'
    ja .mk
    cmp al, '4'
    jne .lv
    mov byte [xo_mode], 2
    jmp .new
.lv:
    sub al, '0'
    mov [xo_lvl], al
.new:
    call get_ticks
    mov [rng], ax
    xor ax, ax
    mov es, ax
    mov di, xox_b
    mov cx, 9
    cld
    rep stosb
    mov byte [xo_turn], 1
.turn:
    call xox_draw
    call xox_check
    test al, al
    jnz .over
    mov byte [attr], 0x07
    mov si, msg_xo_turn
    call print
    cmp byte [xo_turn], 1
    jne .po
    mov byte [attr], 0x0C
    mov al, 'X'
    jmp .pc
.po:
    mov byte [attr], 0x0E
    mov al, 'O'
.pc:
    call putc
    mov byte [attr], 0x07
    mov si, msg_xo_help
    call print
    cmp byte [xo_mode], 1
    jne .key
    cmp byte [xo_turn], 2
    jne .key
    cmp byte [xo_lvl], 3
    je .hard
    cmp byte [xo_lvl], 2
    je .med
    call xox_rand_empty
    jmp .place
.med:
    mov al, 2                    ; kazanabiliyorsa kazan
    call xox_find2
    jnc .place
    mov al, 1                    ; rakibin kazanmasini engelle
    call xox_find2
    jnc .place
    call xox_rand_empty
    jmp .place
.hard:
    mov dl, 2
    xor dh, dh
    call xox_mm
    mov dl, [mm_move]
.place:
    movzx bx, dl
    mov byte [xox_b + bx], 2
    mov byte [xo_turn], 1
    jmp .turn
.key:
    call wait_key
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit
    cmp al, 27
    je .quit
    sub al, '1'
    cmp al, 8
    ja .key
    movzx bx, al
    cmp byte [xox_b + bx], 0
    jne .key
    mov al, [xo_turn]
    mov [xox_b + bx], al
    xor byte [xo_turn], 3
    jmp .turn
.over:
    mov dl, al
    mov byte [attr], 0x0A
    cmp dl, 3
    je .draw
    cmp byte [xo_mode], 1
    jne .two
    mov si, msg_xo_you
    cmp dl, 1
    je .say
    mov si, msg_xo_cpu
    mov byte [attr], 0x0C
    jmp .say
.two:
    mov si, msg_xo_xw
    cmp dl, 1
    je .say
    mov si, msg_xo_ow
    jmp .say
.draw:
    mov si, msg_xo_draw
    mov byte [attr], 0x0E
.say:
    call print
    mov byte [attr], 0x07
    mov si, msg_xo_again
    call print
    call wait_key
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit
    cmp al, 27
    je .quit
    jmp .new
.quit:
    call clear_screen
    ret

; AL = oyuncu (1/2): iki taşi olup ucuncusu bos olan satir -> DL = bos hucre, CF=0
; bulunamazsa CF=1
xox_find2:
    push bx
    push cx
    push si
    push di
    mov [xo_p], al
    mov si, win_tbl
    mov cx, 8
.l: mov byte [xo_cnt], 0
    mov byte [xo_emp], 0xFF
    xor di, di
.j: mov bx, si                   ; 16 bit adreslemede [si+di] gecersiz
    add bx, di
    movzx bx, byte [bx]
    mov al, [xox_b + bx]
    test al, al
    jnz .nz
    mov [xo_emp], bl
    jmp .jn
.nz:
    cmp al, [xo_p]
    jne .bad
    inc byte [xo_cnt]
.jn:
    inc di
    cmp di, 3
    jb .j
    cmp byte [xo_cnt], 2
    jne .bad
    cmp byte [xo_emp], 0xFF
    je .bad
    mov dl, [xo_emp]
    clc
    jmp .ret
.bad:
    add si, 3
    dec cx
    jnz .l
    stc
.ret:
    pop di
    pop si
    pop cx
    pop bx
    ret

; rastgele bos hucre -> DL
xox_rand_empty:
    push ax
    push bx
    push cx
    push si
    xor cx, cx
    xor bx, bx
.c: cmp bx, 9
    jae .cd
    cmp byte [xox_b + bx], 0
    jne .cn
    inc cx
.cn:
    inc bx
    jmp .c
.cd:
    call xo_rand
    xor dx, dx
    div cx
    mov si, dx
    xor bx, bx
.f: cmp byte [xox_b + bx], 0
    jne .fn
    test si, si
    jz .got
    dec si
.fn:
    inc bx
    jmp .f
.got:
    mov dl, bl
    pop si
    pop cx
    pop bx
    pop ax
    ret

xo_rand:                         ; AX = sahte rastgele sayi
    push dx
    mov ax, [rng]
    mov dx, 25173
    mul dx
    add ax, 13849
    mov [rng], ax
    shr ax, 4
    pop dx
    ret

xox_draw:
    call clear_screen
    mov byte [attr], 0x0E
    mov si, msg_xo_title
    call print
    movzx bx, byte [xo_lvl]
    cmp byte [xo_mode], 2
    jne .nm
    xor bx, bx
.nm:
    shl bx, 1
    mov si, [lvl_names + bx]
    call print
    xor bx, bx
.row:
    cmp bx, 9
    jae .done
    mov byte [attr], 0x07
    mov si, msg_xo_ind
    call print
    call xox_cell
    mov al, '|'
    call putc
    inc bx
    call xox_cell
    mov al, '|'
    call putc
    inc bx
    call xox_cell
    inc bx
    mov al, 10
    call putc
    cmp bx, 9
    jae .done
    mov si, msg_xo_sep
    call print
    jmp .row
.done:
    ret

xox_cell:                        ; BX = hucre -> " X " renkli
    push ax
    mov byte [attr], 0x07
    mov al, ' '
    call putc
    mov al, [xox_b + bx]
    cmp al, 1
    je .x
    cmp al, 2
    je .o
    mov byte [attr], 0x08
    mov al, '1'
    add al, bl
    jmp .p
.x: mov byte [attr], 0x0C
    mov al, 'X'
    jmp .p
.o: mov byte [attr], 0x0E
    mov al, 'O'
.p: call putc
    mov byte [attr], 0x07
    mov al, ' '
    call putc
    pop ax
    ret

; AL = 0 devam, 1 X kazandi, 2 O kazandi, 3 berabere
xox_check:
    push bx
    push cx
    push si
    mov si, win_tbl
    mov cx, 8
.l: movzx bx, byte [si]
    mov al, [xox_b + bx]
    test al, al
    jz .n
    movzx bx, byte [si + 1]
    cmp al, [xox_b + bx]
    jne .n
    movzx bx, byte [si + 2]
    cmp al, [xox_b + bx]
    jne .n
    jmp .ret
.n: add si, 3
    loop .l
    xor bx, bx
.d: cmp bx, 9
    jae .dr
    cmp byte [xox_b + bx], 0
    je .none
    inc bx
    jmp .d
.dr:
    mov al, 3
    jmp .ret
.none:
    xor al, al
.ret:
    pop si
    pop cx
    pop bx
    ret

; Minimax: DL = sira (1 X, 2 O), DH = derinlik -> AX = skor (O lehine +)
; en iyi hamle [mm_move] (derinlik 0'da)
xox_mm:
    push bx
    push cx
    push dx
    call xox_check
    cmp al, 2
    je .ow
    cmp al, 1
    je .xw
    cmp al, 3
    je .dr
    mov cx, -100
    cmp dl, 2
    je .m
    mov cx, 100
.m: xor bx, bx
.c: cmp bx, 9
    jae .done
    cmp byte [xox_b + bx], 0
    jne .nx
    mov [xox_b + bx], dl
    push dx
    mov al, 3
    sub al, dl
    mov dl, al
    inc dh
    call xox_mm
    pop dx
    mov byte [xox_b + bx], 0
    cmp dl, 2
    je .max
    cmp ax, cx
    jge .nx
    mov cx, ax
    jmp .nx
.max:
    cmp ax, cx
    jle .nx
    mov cx, ax
    test dh, dh
    jnz .nx
    mov [mm_move], bl
.nx:
    inc bx
    jmp .c
.done:
    mov ax, cx
    jmp .ret
.ow:
    mov al, dh
    xor ah, ah
    mov bx, 10
    sub bx, ax
    mov ax, bx
    jmp .ret
.xw:
    mov al, dh
    xor ah, ah
    sub ax, 10
    jmp .ret
.dr:
    xor ax, ax
.ret:
    pop dx
    pop cx
    pop bx
    ret

; =====================================================
; agri: Turkiye haritasi, Agri ili vurgulanir
; =====================================================
cmd_agri:
    call clear_screen
    mov byte [attr], 0x0E
    mov si, msg_ag_title
    call print
    mov si, map_data
.ch:
    cmp byte [si], 0
    je .done
    lodsb
    cmp al, 10
    je .put
    cmp al, ' '
    je .put
    cmp al, '.'
    jne .nd
    mov byte [attr], 0x02
    mov al, 0xB1
    jmp .put
.nd:
    cmp al, '#'
    jne .pl
    mov byte [attr], 0x0C
    mov al, 0xDB
    jmp .put
.pl:
    mov byte [attr], 0x0F
.put:
    call putc
    jmp .ch
.done:
    mov byte [attr], 0x0C
    mov si, msg_ag_l1
    call print
    mov byte [attr], 0x0F
    mov si, msg_ag_l2
    call print
    mov byte [attr], 0x07
    mov si, msg_ag_l3
    call print
    ret

; =====================================================
; adam gibi adam: asagidaki adam_art bolumundeki ASCII resmi gosterir
; (resmi eklemek icin ; ART-BASLA ile ; ART-BITIS arasini degistir)
; =====================================================
cmd_adam:
    mov si, [argptr]
    mov di, s_gibiadam
    call streq
    jne .usage
    call clear_screen
    mov byte [attr], 0x07
    mov si, adam_art
    call print
    call wait_key
    call clear_screen
    ret
.usage:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_adam
    call print
    ret

; =====================================================
; Masaustu (UI): lila ekran, altta koyu lila bar, konsol simgesi
; Simgeye fare ile (PS/2) bas veya Enter / c tusu
; =====================================================
cmd_exit:
    mov byte [ui_exit], 1
    ret

desktop:
    call ui_pal_on
    mov byte [win_open], 0
    mov byte [ui_close_req], 0
    mov byte [cur_freeze], 0
    mov byte [mv_mode], 0
    mov byte [menu_open], 0
    mov byte [clk_pending], 0
    mov byte [rel_pending], 0
    mov byte [ctx_pending], 0
    mov byte [press_state], 0
    mov byte [mbtn], 0
    mov byte [mbtn_r], 0
    mov byte [pk_i], 0
    mov byte [cur_valid], 0
    call ui_vp_full
    mov word [clk_last], 0xFFFF
    call mouse_enable
    mov byte [drag_pending], 0
    mov byte [ui_active], 1
    cmp word [bb_seg], 0         ; titremeyi onlemek icin arka tampon
    jne .hb
    call alloc_page
    jc .hb
    shr eax, 4
    mov [bb_seg], ax
.hb:
    call desk_redraw
.loop:
    call ui_clock
    call mouse_poll
    call long_press_check
    cmp byte [mv_mode], 0
    jne .mv
    cmp byte [menu_open], 0
    jne .menu
    cmp byte [drag_pending], 0
    jne .drag
    cmp byte [ctx_pending], 0
    jne .ctx
    cmp byte [rel_pending], 0
    jne .rel
    mov ah, 1
    int 0x16
    jz .loop
    xor ah, ah
    int 0x16
    cmp al, 13
    je .console
    cmp al, 'c'
    je .console
    cmp al, 'C'
    je .console
    jmp .loop

.ctx:                            ; sag tik / uzun sol tik: simge uzerindeyse menu ac
    mov byte [ctx_pending], 0
    mov ax, [ctx_row]
    mov bx, [ctx_col]
    call hit_test
    cmp al, 0xFF
    je .loop
    mov [menu_target], al
    mov ax, [ctx_col]
    cmp ax, 61
    jbe .c1
    mov ax, 61
.c1:
    mov [menu_col], ax
    mov ax, [ctx_row]
    cmp ax, 21
    jbe .c2
    mov ax, 21
.c2:
    mov [menu_row], ax
    mov byte [menu_open], 1
    call desk_redraw
    jmp .loop

.drag:                           ; simge uzerinde basip surukle: birakinca yerlesir
    mov byte [drag_pending], 0
    mov ax, [press_y]
    shr ax, 4
    mov bx, [press_x]
    shr bx, 3
    call hit_test
    cmp al, 0xFF
    je .loop
    mov [mv_idx], al
    movzx si, al
    mov ax, [press_x]
    shr ax, 3
    movzx dx, byte [ic_col + si]
    sub ax, dx
    mov [mv_offx], al            ; tutulan nokta simge icinde kalir
    mov ax, [press_y]
    shr ax, 4
    movzx dx, byte [ic_row + si]
    sub ax, dx
    mov [mv_offy], al
    mov byte [mv_mode], 3
    mov word [mv_lastx], 0xFFFF
    call desk_redraw
    jmp .loop

.rel:                            ; kisa sol tik: simgeyi ac
    mov byte [rel_pending], 0
    mov ax, [press_y]
    shr ax, 4
    mov bx, [press_x]
    shr bx, 3
    call hit_test
    cmp al, 0xFF
    jne .app
    mov ax, [press_y]
    shr ax, 4
    cmp ax, 24                   ; gorev cubugundaki konsol simgesi
    jne .loop
    mov bx, [press_x]
    shr bx, 3
    cmp bx, 1
    jb .loop
    cmp bx, 4
    ja .loop
    jmp .console
.app:
    movzx bx, al
    mov al, [ic_type + bx]
    cmp al, 2
    je .paint
    cmp al, 3
    je .trash
.console:
    call mouse_hide
    mov word [win_title], msg_win_title
    call ui_window_draw          ; konsol, masaustunde bir pencere olarak acilir
    mov byte [win_open], 1
    call shell_run
    jmp desktop
.paint:
    call paint_app
    jmp desktop
.trash:
    call trash_app
    jmp desktop

.menu:                           ; baglam menusu acik
    cmp byte [ctx_pending], 0
    je .m1
    mov byte [ctx_pending], 0
    jmp .mclose
.m1:
    cmp byte [rel_pending], 0
    je .loop
    mov byte [rel_pending], 0
    mov ax, [press_y]
    shr ax, 4
    mov bx, [press_x]
    shr bx, 3
    cmp bx, [menu_col]
    jb .mclose
    mov dx, [menu_col]
    add dx, 18
    cmp bx, dx
    ja .mclose
    mov dx, [menu_row]
    inc dx
    cmp ax, dx
    je .mtas
    inc dx
    cmp ax, dx
    je .mkop
.mclose:
    mov byte [menu_open], 0
    call desk_redraw
    jmp .loop
.mtas:
    mov byte [mv_mode], 1        ; tasi: simge imlecle birlikte gelir
    jmp .mst
.mkop:
    movzx bx, byte [menu_target]
    cmp byte [ic_type + bx], 3   ; cop kutusu kopyalanmaz
    je .mclose
    mov byte [mv_mode], 2        ; kopyala ve tasi: asil yerinde kalir, kopya gelir
.mst:
    mov byte [mv_offx], 3        ; menuden tasi: simge imlecin ortasinda gelir
    mov byte [mv_offy], 1
    mov byte [menu_open], 0
    mov al, [menu_target]
    mov [mv_idx], al
    mov word [mv_lastx], 0xFFFF
    call desk_redraw
    jmp .loop

.mv:                             ; tasima / kopyalama / surukleme modu
    cmp byte [mv_mode], 3
    jne .mvn
    cmp byte [ctx_pending], 0
    je .dr1
    mov byte [ctx_pending], 0    ; sag tik: iptal
    mov byte [mv_mode], 0
    call desk_redraw
    jmp .loop
.dr1:
    cmp byte [mbtn], 0
    jne .mv2                     ; tus hala basili: hareketi izle
    call place_icon              ; tus birakildi: yerlestir
    mov byte [mv_mode], 0
    call desk_redraw
    call settings_save
    jmp .loop
.mvn:
    cmp byte [ctx_pending], 0
    je .mv1
    mov byte [ctx_pending], 0    ; sag tik: iptal
    mov byte [mv_mode], 0
    call desk_redraw
    jmp .loop
.mv1:
    cmp byte [rel_pending], 0
    je .mv2
    mov byte [rel_pending], 0    ; bir tik: simge oraya yerlesir
    call place_icon
    mov byte [mv_mode], 0
    call desk_redraw
    call settings_save
    jmp .loop
.mv2:
    mov ax, [mpx]
    shr ax, 3
    mov bx, [mpy]
    shr bx, 4
    cmp ax, [mv_lastx]
    jne .mv3
    cmp bx, [mv_lasty]
    je .loop
.mv3:
    mov [mv_lastx], ax
    mov [mv_lasty], bx
    call desk_redraw
    jmp .loop

long_press_check:                ; sol tus ~0,5 sn basili tutulursa baglam olayi uret
    cmp byte [press_state], 1
    jne .r
    push eax
    call get_ticks
    sub eax, [press_tick]
    cmp eax, 9
    jb .p
    mov byte [press_state], 2
    mov ax, [press_y]
    shr ax, 4
    mov [ctx_row], ax
    mov ax, [press_x]
    shr ax, 3
    mov [ctx_col], ax
    mov byte [ctx_pending], 1
.p: pop eax
.r: ret

hit_test:                        ; AX = satir, BX = sutun -> AL = simge no (0xFF yok)
    push bx
    push cx
    push dx
    push si
    movzx si, byte [ic_n]
.l: test si, si
    jz .none
    dec si
    movzx dx, byte [ic_col + si]
    cmp bx, dx
    jb .l
    add dx, 7
    cmp bx, dx
    ja .l
    movzx dx, byte [ic_row + si]
    cmp ax, dx
    jb .l
    add dx, 3
    cmp ax, dx
    ja .l
    mov ax, si
    jmp .d
.none:
    mov al, 0xFF
.d: pop si
    pop dx
    pop cx
    pop bx
    ret

ptr_icon_pos:                    ; BL = satir, BH = sutun (imlec - tutma noktasi, ekran icinde)
    push ax
    push dx
    mov ax, [mpx]
    shr ax, 3
    movzx dx, byte [mv_offx]
    sub ax, dx
    jge .a1
    xor ax, ax
.a1:
    cmp ax, 72
    jbe .a2
    mov ax, 72
.a2:
    mov bh, al
    mov ax, [mpy]
    shr ax, 4
    movzx dx, byte [mv_offy]
    sub ax, dx
    jge .b1
    xor ax, ax
.b1:
    cmp ax, 19
    jbe .b2
    mov ax, 19
.b2:
    mov bl, al
    pop dx
    pop ax
    ret

place_icon:                      ; tasi / kopyala; cop kutusuna birakilirsa sil
    call find_trash
    cmp al, 0xFF
    je .norm
    movzx si, al
    movzx bx, byte [mv_idx]
    cmp byte [ic_type + bx], 3
    je .norm
    mov ax, [mpx]
    shr ax, 3
    movzx dx, byte [ic_col + si]
    cmp ax, dx
    jb .norm
    add dx, 7
    cmp ax, dx
    ja .norm
    mov ax, [mpy]
    shr ax, 4
    movzx dx, byte [ic_row + si]
    cmp ax, dx
    jb .norm
    add dx, 3
    cmp ax, dx
    ja .norm
    cmp byte [mv_mode], 2        ; kopya cop kutusuna birakilirsa iptal
    je .r
    mov al, [mv_idx]
    call del_icon
    ret
.norm:
    call ptr_icon_pos
    movzx si, byte [mv_idx]
    cmp byte [mv_mode], 2
    je .copy
    mov [ic_col + si], bh
    mov [ic_row + si], bl
    ret
.copy:
    movzx di, byte [ic_n]
    cmp di, 12
    jae .r
    mov al, [ic_type + si]
    mov [ic_type + di], al
    mov [ic_col + di], bh
    mov [ic_row + di], bl
    mov dl, [ic_par + si]        ; kopyanin bagli oldugu orijinal
    test dl, dl
    jnz .hp
    mov dl, [ic_id + si]
.hp:
    mov [ic_par + di], dl
    call new_id
    mov [ic_id + di], al
    inc byte [ic_n]
.r: ret

new_id:                          ; AL = kullanilmayan en kucuk simge kimligi
    push cx
    push si
    mov al, 1
.t: movzx cx, byte [ic_n]
    xor si, si
.s: cmp si, cx
    jae .ok
    cmp [ic_id + si], al
    je .nx
    inc si
    jmp .s
.nx:
    inc al
    jmp .t
.ok:
    pop si
    pop cx
    ret

find_trash:                      ; AL = cop kutusu simge no (0xFF yok)
    push bx
    push cx
    movzx cx, byte [ic_n]
    xor bx, bx
.l: cmp bx, cx
    jae .n
    cmp byte [ic_type + bx], 3
    je .f
    inc bx
    jmp .l
.f: mov al, bl
    jmp .d
.n: mov al, 0xFF
.d: pop cx
    pop bx
    ret

rm_icon:                         ; AL = silinecek simge, ustundekiler kayar
    pusha
    movzx si, al
.l: mov bx, si
    inc bx
    movzx cx, byte [ic_n]
    cmp bx, cx
    jae .d
    mov al, [ic_type + bx]
    mov [ic_type + si], al
    mov al, [ic_col + bx]
    mov [ic_col + si], al
    mov al, [ic_row + bx]
    mov [ic_row + si], al
    mov al, [ic_id + bx]
    mov [ic_id + si], al
    mov al, [ic_par + bx]
    mov [ic_par + si], al
    mov si, bx
    jmp .l
.d: dec byte [ic_n]
    popa
    ret

del_icon:                        ; AL = simge no: orijinal silinirse kopyalari da cop kutusuna gelir
    pusha
    movzx si, al
    cmp byte [ic_type + si], 3
    je .r                        ; cop kutusu silinmez
    cmp byte [ic_par + si], 0
    jne .one
    mov bh, [ic_id + si]
    movzx cx, byte [ic_n]
.cp:
    test cx, cx
    jz .orig
    dec cx
    mov di, cx
    cmp [ic_par + di], bh
    jne .cp
    mov al, cl
    call to_trash
    jmp .cp
.orig:
    xor si, si
.f: movzx ax, byte [ic_n]
    cmp si, ax
    jae .r
    cmp [ic_id + si], bh
    je .rmo
    inc si
    jmp .f
.rmo:
    mov ax, si
    call to_trash
    jmp .r
.one:
    mov ax, si
    call to_trash
.r: popa
    ret

to_trash:                        ; AL = simge no: cop kutusuna ekle, masaustunden cikar
    pusha
    movzx si, al
    movzx di, byte [tr_n]
    cmp di, 12
    jae .rm
    mov al, [ic_type + si]
    mov [tr_type + di], al
    mov al, [ic_col + si]
    mov [tr_col + di], al
    mov al, [ic_row + si]
    mov [tr_row + di], al
    mov al, [ic_par + si]
    test al, al
    jz .o
    mov byte [tr_kind + di], 1   ; kopya: bagli oldugu orijinalin kimligi
    mov [tr_id + di], al
    jmp .a
.o: mov byte [tr_kind + di], 0
    mov al, [ic_id + si]
    mov [tr_id + di], al
.a: inc byte [tr_n]
.rm:
    mov ax, si
    call rm_icon
    popa
    ret

tr_rm:                           ; AL = cop girdisi: sil, ustundekiler kayar
    pusha
    movzx si, al
.l: mov bx, si
    inc bx
    movzx cx, byte [tr_n]
    cmp bx, cx
    jae .d
    mov al, [tr_type + bx]
    mov [tr_type + si], al
    mov al, [tr_kind + bx]
    mov [tr_kind + si], al
    mov al, [tr_id + bx]
    mov [tr_id + si], al
    mov al, [tr_col + bx]
    mov [tr_col + si], al
    mov al, [tr_row + bx]
    mov [tr_row + si], al
    mov si, bx
    jmp .l
.d: dec byte [tr_n]
    popa
    ret

id_exists:                       ; AL = kimlik -> CF=0 masaustunde varsa (AL korunur)
    push cx
    push si
    movzx cx, byte [ic_n]
    xor si, si
.l: cmp si, cx
    jae .no
    cmp [ic_id + si], al
    je .yes
    inc si
    jmp .l
.yes:
    clc
    jmp .d
.no:
    stc
.d: pop si
    pop cx
    ret

ic_append:                       ; [a_type] [a_col] [a_row] [a_id] [a_par] -> masaustune ekle
    push di
    push ax
    movzx di, byte [ic_n]
    cmp di, 12
    jae .r
    mov al, [a_type]
    mov [ic_type + di], al
    mov al, [a_col]
    mov [ic_col + di], al
    mov al, [a_row]
    mov [ic_row + di], al
    mov al, [a_id]
    mov [ic_id + di], al
    mov al, [a_par]
    mov [ic_par + di], al
    inc byte [ic_n]
.r: pop ax
    pop di
    ret

trash_restore:                   ; SI = cop girdisi: geri al (orijinalse kopyalariyla birlikte)
    pusha
    cmp byte [tr_kind + si], 0
    jne .copy
    mov bl, [tr_id + si]         ; eski kimlik
    mov al, bl
    call id_exists
    jc .free
    call new_id                  ; kimlik doluysa yenisi
.free:
    mov bh, al
    mov al, [tr_type + si]
    mov [a_type], al
    mov al, [tr_col + si]
    mov [a_col], al
    mov al, [tr_row + si]
    mov [a_row], al
    mov [a_id], bh
    mov byte [a_par], 0
    call ic_append
    movzx cx, byte [tr_n]
.j: test cx, cx
    jz .done
    dec cx
    mov di, cx
    cmp di, si
    je .rm
    cmp byte [tr_kind + di], 1
    jne .j
    cmp [tr_id + di], bl
    jne .j
    mov al, [tr_type + di]       ; bu orijinalin kopyasi: o da geri gelir
    mov [a_type], al
    mov al, [tr_col + di]
    mov [a_col], al
    mov al, [tr_row + di]
    mov [a_row], al
    call new_id
    mov [a_id], al
    mov [a_par], bh
    call ic_append
.rm:
    mov al, cl
    call tr_rm
    jmp .j
.done:
    popa
    ret
.copy:
    mov al, [tr_id + si]
    call id_exists
    jc .none                     ; orijinal masaustunde degil: once onu geri al
    mov bh, al
    mov al, [tr_type + si]
    mov [a_type], al
    mov al, [tr_col + si]
    mov [a_col], al
    mov al, [tr_row + si]
    mov [a_row], al
    call new_id
    mov [a_id], al
    mov [a_par], bh
    call ic_append
    mov ax, si
    call tr_rm
.none:
    popa
    ret

add_icon_orig:                   ; AL = tur: orijinal simgeyi masaustune geri koy
    pusha
    movzx di, byte [ic_n]
    cmp di, 12
    jae .r
    mov [ic_type + di], al
    mov byte [ic_col + di], 4
    mov byte [ic_row + di], 2
    cmp al, 1
    jne .p
    mov byte [ic_row + di], 7
.p: mov byte [ic_par + di], 0
    call new_id
    mov [ic_id + di], al
    inc byte [ic_n]
.r: popa
    ret

draw_icon:                       ; AL = tur (1 konsol, 2 paint), BL = satir, BH = sutun
    pusha
    mov [ico_t], al
    mov [ico_r], bl
    mov [ico_c], bh
    mov si, ico_console
    cmp al, 2
    jne .t1
    mov si, ico_paint
.t1:
    cmp al, 3
    jne .t
    mov si, ico_trash
.t: movzx ax, bl
    mov dx, 160
    mul dx
    movzx di, bh
    inc di
    shl di, 1
    add di, ax
    mov cx, 3
.r: push cx
    push di
    mov cx, 6
.c: lodsw
    mov [gs:di], ax
    add di, 2
    loop .c
    pop di
    pop cx
    add di, 160
    loop .r
    mov si, lbl_console
    cmp byte [ico_t], 2
    jne .l0
    mov si, lbl_paint
.l0:
    cmp byte [ico_t], 3
    jne .l1
    mov si, lbl_trash
.l1:
    xor cx, cx
    mov di, si
.n: cmp byte [di], 0
    je .nd
    inc cx
    inc di
    jmp .n
.nd:
    mov al, 8
    sub al, cl
    shr al, 1
    add al, [ico_c]
    mov bh, al
    mov bl, [ico_r]
    add bl, 3
    mov ah, 0x5F
    call ui_textat
    cmp byte [ico_copy], 0       ; kopyalarin altinda beyaz nokta
    je .nd2
    mov ah, 0x5F
    mov bl, [ico_r]
    add bl, 4
    mov bh, [ico_c]
    add bh, 3
    mov si, str_dot
    call ui_textat
.nd2:
    popa
    ret

draw_menu:
    pusha
    mov bl, [menu_row]
    mov bh, [menu_col]
    mov cx, 19
    mov ax, 0xDF20
    call ui_fill
    inc bl
    mov ax, 0xF020
    call ui_fill
    inc bl
    mov ax, 0xF020
    call ui_fill
    inc bl
    mov ax, 0xDF20
    call ui_fill
    mov bl, [menu_row]
    inc bl
    mov bh, [menu_col]
    mov ah, 0xF0
    mov si, msg_m_tasi
    call ui_textat
    inc bl
    mov ah, 0xF0
    mov si, msg_m_kopya
    call ui_textat
    popa
    ret

desk_redraw:                     ; arka tamponda ciz, ekrana tek seferde kopyala (titremez)
    pusha
    push es
    push gs
    mov byte [cur_valid], 0
    mov ax, [bb_seg]
    test ax, ax
    jz .ds
    mov gs, ax
.ds:
    call ui_draw
    xor si, si
.l: movzx ax, byte [ic_n]
    cmp si, ax
    jae .g
    mov al, [mv_mode]
    cmp al, 1
    je .sk
    cmp al, 3
    jne .dr
.sk:
    movzx ax, byte [mv_idx]
    cmp si, ax
    je .nx
.dr:
    mov dl, [ic_par + si]
    mov [ico_copy], dl
    mov al, [ic_type + si]
    mov bl, [ic_row + si]
    mov bh, [ic_col + si]
    call draw_icon
.nx:
    inc si
    jmp .l
.g: cmp byte [mv_mode], 0
    je .m
    movzx si, byte [mv_idx]
    mov dl, [ic_par + si]
    cmp byte [mv_mode], 2
    jne .gn
    mov dl, 1
.gn:
    mov [ico_copy], dl
    mov al, [ic_type + si]
    call ptr_icon_pos
    call draw_icon
.m: cmp byte [menu_open], 0
    je .d
    call draw_menu
.d: call ui_clock
    cmp word [bb_seg], 0
    je .no
    push ds
    mov ax, [bb_seg]
    mov ds, ax
    xor si, si
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov cx, 2000
    cld
    rep movsw
    pop ds
.no:
    pop gs
    pop es
    popa
    call mouse_cursor_update
    ret

icons_default:
    mov byte [ic_n], 3
    mov byte [tr_n], 0
    mov byte [ic_type], 2        ; Paint
    mov byte [ic_col], 4
    mov byte [ic_row], 2
    mov byte [ic_id], 1
    mov byte [ic_par], 0
    mov byte [ic_type + 1], 1    ; Konsol
    mov byte [ic_col + 1], 4
    mov byte [ic_row + 1], 7
    mov byte [ic_id + 1], 2
    mov byte [ic_par + 1], 0
    mov byte [ic_type + 2], 3    ; Cop kutusu
    mov byte [ic_col + 2], 70
    mov byte [ic_row + 2], 19
    mov byte [ic_id + 2], 3
    mov byte [ic_par + 2], 0
    ret

ui_vp_full:                      ; goruntu alani = tum ekran
    mov word [vp_x0], 0
    mov word [vp_y0], 0
    mov word [vp_x1], 79
    mov word [vp_y1], 24
    ret

ui_window_draw:                  ; cerceve 2..77 x 1..22, icerik 3..76 x 2..21
    pusha
    push es
    mov ax, 0xB800
    mov es, ax
    mov bx, 1
    cld
.fr:
    mov ax, bx
    mov cx, 160
    mul cx
    add ax, 4
    mov di, ax
    mov cx, 76
    mov ax, 0xDF20
    rep stosw
    inc bx
    cmp bx, 22
    jbe .fr
    pop es
    mov ah, 0xDF
    mov si, [win_title]
    mov di, 160 + 6
    call ui_text
    mov ah, 0x4F
    mov si, msg_win_x
    mov di, 160 + 148
    call ui_text
    mov word [vp_x0], 3
    mov word [vp_y0], 2
    mov word [vp_x1], 76
    mov word [vp_y1], 21
    popa
    call clear_screen
    ret

ui_pal_on:                       ; lila renkler (DAC 5 = ekran, DAC 61 = bar)
    mov ax, 0x1010
    mov bx, 5
    mov dh, 50
    mov ch, 40
    mov cl, 55
    int 0x10
    mov ax, 0x1010
    mov bx, 0x3D
    mov dh, 35
    mov ch, 27
    mov cl, 42
    int 0x10
    ret

ui_pal_off:                      ; varsayilan mor tonlarini geri yukle
    mov ax, 0x1010
    mov bx, 5
    mov dh, 42
    mov ch, 0
    mov cl, 42
    int 0x10
    mov ax, 0x1010
    mov bx, 0x3D
    mov dh, 63
    mov ch, 21
    mov cl, 63
    int 0x10
    ret

ui_text:                         ; SI = metin, DI = VRAM ofseti, AH = renk
    push ax
    push si
    push di
.l: lodsb
    test al, al
    jz .d
    mov [gs:di], ax
    add di, 2
    jmp .l
.d: pop di
    pop si
    pop ax
    ret

ui_base:                         ; lila zemin + koyu lila bar (+ saat yeniden cizilsin)
    pusha
    push es
    push gs
    pop es                       ; hedef: GS (arka tampon ya da ekran)
    xor di, di
    mov cx, 2000
    mov ax, 0x5F20
    cld
    rep stosw
    mov di, 3840
    mov cx, 80
    mov ax, 0xDF20
    rep stosw
    pop es
    mov word [clk_last], 0xFFFF
    popa
    ret

ui_draw:
    call ui_base
    pusha
    mov ah, 0x0A                 ; konsol simgesi: siyah kutuda yesil >_
    mov si, msg_ui_icon
    mov di, 24 * 160 + 2
    call ui_text
    popa
    ret

ui_clock:                        ; sag altta SS:DD (RTC), saniyede bir guncellenir
    pusha
    call get_ticks
    shr eax, 4
    cmp ax, [clk_last]
    je .r
    mov [clk_last], ax
    mov ah, 2
    int 0x1A
    jc .r
    mov bl, cl
    mov dl, ch
    mov ah, 0xDF
    mov di, 24 * 160 + 148
    mov al, dl
    shr al, 4
    add al, '0'
    mov [gs:di], ax
    mov al, dl
    and al, 0x0F
    add al, '0'
    mov [gs:di + 2], ax
    mov al, ':'
    mov [gs:di + 4], ax
    mov al, bl
    shr al, 4
    add al, '0'
    mov [gs:di + 6], ax
    mov al, bl
    and al, 0x0F
    add al, '0'
    mov [gs:di + 8], ax
.r: popa
    ret

; ---- PS/2 fare (8042 uzerinden, zaman asimli)
kbc_wait_in:                     ; giris tamponu bos olana kadar, CF=1 zaman asimi
    push cx
    mov cx, 0xFFFF
.l: in al, 0x64
    test al, 2
    jz .ok
    loop .l
    pop cx
    stc
    ret
.ok:
    pop cx
    clc
    ret

kbc_wait_out:                    ; cikis tamponu dolana kadar, CF=1 zaman asimi
    push cx
    mov cx, 0xFFFF
.l: in al, 0x64
    test al, 1
    jnz .ok
    loop .l
    pop cx
    stc
    ret
.ok:
    pop cx
    clc
    ret

mouse_cmd:                       ; AL = fareye komut, CF=1 ACK gelmedi
    push ax
    push cx
    mov ah, al
    call kbc_wait_in
    jc .f
    mov al, 0xD4
    out 0x64, al
    call kbc_wait_in
    jc .f
    mov al, ah
    out 0x60, al
    mov cx, 16
.a: call kbc_wait_out
    jc .f
    in al, 0x60
    cmp al, 0xFA
    je .ok
    loop .a
.f: pop cx
    pop ax
    stc
    ret
.ok:
    pop cx
    pop ax
    clc
    ret

mouse_enable:
    mov byte [mouse_ok], 0
    call kbc_wait_in
    jc .r
    mov al, 0xA8                 ; ikinci (fare) portu ac
    out 0x64, al
    mov al, 0xF4                 ; veri gondermeyi baslat
    call mouse_cmd
    jc .r
    mov byte [mouse_ok], 1
.r: ret

mouse_disable:                   ; konsolda klavye karismasin diye fareyi sustur
    cmp byte [mouse_ok], 0
    je .r
    mov al, 0xF5
    call mouse_cmd
    mov cx, 64
.f: in al, 0x64
    test al, 1
    jz .r
    in al, 0x60
    loop .f
.r: ret

mouse_poll:
    cmp byte [mouse_ok], 0
    je .r
    push ax
    push bx
.rd:
    in al, 0x64
    test al, 1
    jz .d
    test al, 0x20                ; klavye verisiyse BIOS'a birak
    jz .d
    in al, 0x60
    movzx bx, byte [pk_i]
    test bx, bx
    jnz .st
    test al, 8                   ; ilk bayt senkron biti
    jz .rd
.st:
    mov [pk_buf + bx], al
    inc bx
    mov [pk_i], bl
    cmp bl, 3
    jb .rd
    mov byte [pk_i], 0
    call mouse_apply
    jmp .rd
.d: pop bx
    pop ax
.r: ret

mouse_apply:                     ; 3 baytlik paketi isle
    push ax
    push bx
    push cx
    mov bl, [pk_buf]
    movzx ax, byte [pk_buf + 1]
    test bl, 0x10
    jz .x1
    sub ax, 256
.x1:
    add [mpx], ax
    cmp word [mpx], 0
    jge .x2
    mov word [mpx], 0
.x2:
    cmp word [mpx], 639
    jle .y0
    mov word [mpx], 639
.y0:
    movzx ax, byte [pk_buf + 2]
    test bl, 0x20
    jz .y1
    sub ax, 256
.y1:
    neg ax
    add [mpy], ax
    cmp word [mpy], 0
    jge .y2
    mov word [mpy], 0
.y2:
    cmp word [mpy], 399
    jle .b
    mov word [mpy], 399
.b: cmp byte [press_state], 1    ; uzun basma: baslangic noktasindan uzaklasildiysa iptal
    jne .rb
    mov ax, [mpx]
    sub ax, [press_x]
    jns .d1
    neg ax
.d1:
    cmp ax, 12
    ja .cn
    mov ax, [mpy]
    sub ax, [press_y]
    jns .d2
    neg ax
.d2:
    cmp ax, 12
    jbe .rb
.cn:
    mov byte [press_state], 0
    mov byte [drag_pending], 1   ; basili tutup surukleme basladi
.rb:
    mov al, bl                   ; sag tus
    shr al, 1
    and al, 1
    cmp al, [mbtn_r]
    je .lt
    mov [mbtn_r], al
    test al, al
    jz .lt
    mov ax, [mpy]
    shr ax, 4
    mov [ctx_row], ax
    mov ax, [mpx]
    shr ax, 3
    mov [ctx_col], ax
    mov byte [ctx_pending], 1
.lt:
    mov al, bl                   ; sol tus
    and al, 1
    cmp al, [mbtn]
    je .nb
    mov [mbtn], al
    test al, al
    jz .rel
    call get_ticks               ; uzun basma icin zaman damgasi
    mov [press_tick], eax
    mov byte [press_state], 1
    mov ax, [mpx]
    mov [press_x], ax
    mov ax, [mpy]
    mov [press_y], ax
    shr ax, 4
    mov bx, [mpx]
    shr bx, 3
    mov [clk_row], ax
    mov [clk_col], bx
    mov byte [clk_pending], 1
    cmp byte [win_open], 0
    jne .win
    cmp ax, 24
    jne .nb
    cmp bx, 1
    jb .nb
    cmp bx, 4
    ja .nb
    mov byte [ui_click], 1
    jmp .nb
.win:
    cmp ax, 1
    jne .nb
    cmp bx, 74
    jb .nb
    cmp bx, 76
    ja .nb
    mov byte [ui_close_req], 1
    jmp .nb
.rel:
    cmp byte [press_state], 1    ; kisa tiklama: birakinca olay uret
    jne .rl
    mov byte [rel_pending], 1
.rl:
    mov byte [press_state], 0
.nb:
    call mouse_cursor_update
    pop cx
    pop bx
    pop ax
    ret

mouse_cursor_update:             ; fare imleci: ok simgesi (hucrenin arka plani korunur)
    cmp byte [mouse_ok], 0
    je .r
    cmp byte [cur_freeze], 0
    jne .r
    pusha
    cmp byte [cur_valid], 0
    je .nr
    mov di, [cur_off]
    mov ax, [cur_saved]
    mov [gs:di], ax
.nr:
    mov ax, [mpy]
    shr ax, 4
    mov bx, 160
    mul bx
    mov di, ax
    mov ax, [mpx]
    shr ax, 3
    shl ax, 1
    add di, ax
    mov [cur_off], di
    mov ax, [gs:di]
    mov [cur_saved], ax
    mov bl, ah
    shr bl, 4
    xor bh, bh
    mov dl, 0x0F                 ; koyu zemin: beyaz ok
    cmp byte [bg_light + bx], 0
    je .wh
    xor dl, dl                   ; acik zemin: siyah ok
.wh:
    and ah, 0xF0
    or ah, dl
    mov al, 0x87
    mov [gs:di], ax
    mov byte [cur_valid], 1
    popa
.r: ret

mouse_hide:                      ; imleci sil (altindaki hucreyi geri koy)
    cmp byte [cur_valid], 0
    je .r
    push ax
    push di
    mov di, [cur_off]
    mov ax, [cur_saved]
    mov [gs:di], ax
    mov byte [cur_valid], 0
    pop di
    pop ax
.r: ret

; =====================================================
; time -d | -t | -m | -h   ve   file -h
; =====================================================
cmd_time:
    mov si, [argptr]
    cmp byte [si], 0
    je .bad
    cmp byte [si], '-'
    jne .bad
    cmp byte [si + 2], 0
    jne .bad
    mov al, [si + 1]
    cmp al, 'h'
    je .help
    cmp al, 'd'
    je .d
    cmp al, 't'
    je .t
    cmp al, 'm'
    je .m
.bad:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_time
    call print
    ret
.help:
    mov si, time_table
    jmp print_table
.d: call print_date
    jmp .nl
.t: call print_clock
    jmp .nl
.m: call print_date
    mov al, ' '
    call putc
    call print_clock
.nl:
    mov al, 10
    call putc
    ret

put_bcd:                         ; AL = BCD -> iki rakam
    push ax
    push ax
    shr al, 4
    add al, '0'
    call putc
    pop ax
    and al, 0x0F
    add al, '0'
    call putc
    pop ax
    ret

print_date:                      ; GG.AA.YYYY (RTC)
    push ax
    push bx
    push cx
    push dx
    mov byte [attr], 0x0B
    mov ah, 4
    int 0x1A
    jc .r
    mov bx, cx                   ; BH = yuzyil, BL = yil
    mov al, dl
    call put_bcd
    mov al, '.'
    call putc
    mov al, dh
    call put_bcd
    mov al, '.'
    call putc
    mov al, bh
    call put_bcd
    mov al, bl
    call put_bcd
.r: pop dx
    pop cx
    pop bx
    pop ax
    ret

print_clock:                     ; SS:DD:SN (RTC)
    push ax
    push bx
    push cx
    push dx
    mov byte [attr], 0x0B
    mov ah, 2
    int 0x1A
    jc .r
    mov bl, cl
    mov bh, dh
    mov al, ch
    call put_bcd
    mov al, ':'
    call putc
    mov al, bl
    call put_bcd
    mov al, ':'
    call putc
    mov al, bh
    call put_bcd
.r: pop dx
    pop cx
    pop bx
    pop ax
    ret

cmd_file:
    mov si, [argptr]
    cmp byte [si], 0
    je .bad
    cmp byte [si], '-'
    jne .bad
    cmp byte [si + 1], 'h'
    jne .bad
    cmp byte [si + 2], 0
    jne .bad
.show:
    mov si, file_table
    jmp print_table
.bad:
    mov al, ERR_USAGE
    call error
    mov si, msg_usage_file2
    call print
    ret

; =====================================================
; Ilk acilis (Merhaba), kullanici kaydi ve kilit ekrani
; =====================================================
startup:
    call settings_load
    cmp byte [u_state], 0
    jne .have
    call welcome_screen          ; ilk acilis: Merhaba -> ileri -> hesap
    call setup_screen
    jmp desktop
.have:
    cmp byte [u_state], 2
    jne desktop                  ; atla secilmisse kilit yok
    call lock_screen
    jmp desktop

ui_prep:                         ; UI ekranlari icin ortak hazirlik
    call ui_pal_on
    call ui_vp_full
    mov byte [win_open], 0
    mov byte [cur_freeze], 0
    mov byte [cur_valid], 0
    mov byte [mbtn], 0
    mov byte [pk_i], 0
    mov byte [clk_pending], 0
    mov byte [ui_close_req], 0
    call ui_base
    call mouse_enable
    mov byte [ui_active], 1
    ret

ui_textat:                       ; AH = renk, BL = satir, BH = sutun, SI = metin
    push ax
    push bx
    push cx
    push dx
    push di
    mov cl, ah
    movzx ax, bl
    mov dx, 160
    mul dx
    movzx di, bh
    shl di, 1
    add di, ax
    mov ah, cl
    call ui_text
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

ui_ctext:                        ; AH = renk, BL = satir, SI = metin (ortalanir)
    push ax
    push bx
    push cx
    push dx
    push di
    mov [ctx_attr], ah
    xor cx, cx
    mov di, si
.c: cmp byte [di], 0
    je .d
    inc cx
    inc di
    jmp .c
.d: mov ax, 80
    sub ax, cx
    shr ax, 1
    mov bh, al
    mov ah, [ctx_attr]
    call ui_textat
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

ui_fill:                         ; AX = renk:karakter, BL = satir, BH = sutun, CX = genislik
    push ax
    push bx
    push cx
    push di
    push bp
    mov bp, ax
    movzx ax, bl
    push cx
    mov cx, 160
    mul cx
    pop cx
    movzx di, bh
    shl di, 1
    add di, ax
    mov ax, bp
.l: mov [gs:di], ax
    add di, 2
    loop .l
    pop bp
    pop di
    pop cx
    pop bx
    pop ax
    ret

draw_field:                      ; BL=satir BH=sutun CX=genislik SI=tampon [fld_mask] [fld_foc]
    pusha
    mov ax, 0x7020               ; gri kutu
    cmp byte [fld_foc], 0
    je .n
    mov ax, 0xF020               ; odakli: beyaz kutu
.n: mov [fld_attr], ah
    call ui_fill
    movzx ax, bl
    mov dx, 160
    mul dx
    movzx di, bh
    shl di, 1
    add di, ax
    mov ah, [fld_attr]
    xor bx, bx
.l: mov al, [si + bx]
    test al, al
    jz .cur
    cmp byte [fld_mask], 0
    je .p
    mov al, '*'
.p: mov [gs:di], ax
    add di, 2
    inc bx
    jmp .l
.cur:
    cmp byte [fld_foc], 0
    je .done
    mov al, '_'
    mov [gs:di], ax
.done:
    popa
    ret

hash_pass:                       ; SI = metin -> EAX (FNV-1a)
    push edx
    push si
    mov eax, 0x811C9DC5
.l: movzx edx, byte [si]
    test dl, dl
    jz .d
    xor eax, edx
    imul eax, eax, 0x01000193
    inc si
    jmp .l
.d: pop si
    pop edx
    ret

settings_load:                   ; sektor SET_LBA: 'DUSR', durum, ad[16], hash
    pusha
    push es
    xor ax, ax
    mov es, ax
    mov byte [u_state], 0
    call icons_default
    mov word [rw_lba], SET_LBA
    mov bx, FSBUF
    mov ah, 2
    call rw_sector
    jc .r
    cmp dword [FSBUF], 'DUSR'
    jne .r
    mov al, [FSBUF + 4]
    cmp al, 1
    je .ok
    cmp al, 2
    jne .r
.ok:
    mov [u_state], al
    mov si, FSBUF + 5
    mov di, u_name
    mov cx, 16
    cld
    rep movsb
    mov eax, [FSBUF + 21]
    mov [u_hash], eax
    cmp byte [FSBUF + 26], 0xA6
    je .fm
    cmp byte [FSBUF + 26], 0xA5
    jne .r
.fm:
    movzx cx, byte [FSBUF + 25]
    test cx, cx
    jz .r
    cmp cx, 12
    ja .r
    mov [ic_n], cl
    mov si, FSBUF + 27
    xor bx, bx
.li:
    mov al, [si]
    mov [ic_type + bx], al
    mov al, [si + 1]
    mov [ic_col + bx], al
    mov al, [si + 2]
    mov [ic_row + bx], al
    mov al, [si + 3]
    mov [ic_id + bx], al
    mov al, [si + 4]
    mov [ic_par + bx], al
    add si, 5
    inc bx
    cmp bx, cx
    jb .li
    cmp byte [FSBUF + 26], 0xA6  ; cop kutusu (yeni bicim)
    jne .r
    mov al, [FSBUF + 87]
    cmp al, 12
    ja .r
    mov [tr_n], al
    movzx cx, al
    xor bx, bx
    mov si, FSBUF + 88
.lt:
    cmp bx, cx
    jae .r
    mov al, [si]
    mov [tr_type + bx], al
    mov al, [si + 1]
    mov [tr_kind + bx], al
    mov al, [si + 2]
    mov [tr_id + bx], al
    mov al, [si + 3]
    mov [tr_col + bx], al
    mov al, [si + 4]
    mov [tr_row + bx], al
    add si, 5
    inc bx
    jmp .lt
.r: pop es
    popa
    ret

settings_save:                   ; CF=1 hata
    pusha
    push es
    xor ax, ax
    mov es, ax
    mov di, FSBUF
    mov cx, 256
    cld
    rep stosw
    mov dword [FSBUF], 'DUSR'
    mov al, [u_state]
    mov [FSBUF + 4], al
    mov si, u_name
    mov di, FSBUF + 5
    mov cx, 16
    rep movsb
    mov eax, [u_hash]
    mov [FSBUF + 21], eax
    mov al, [ic_n]
    mov [FSBUF + 25], al
    mov byte [FSBUF + 26], 0xA6
    movzx cx, byte [ic_n]
    xor bx, bx
    mov di, FSBUF + 27
.si:
    cmp bx, cx
    jae .sd
    mov al, [ic_type + bx]
    mov [di], al
    mov al, [ic_col + bx]
    mov [di + 1], al
    mov al, [ic_row + bx]
    mov [di + 2], al
    mov al, [ic_id + bx]
    mov [di + 3], al
    mov al, [ic_par + bx]
    mov [di + 4], al
    add di, 5
    inc bx
    jmp .si
.sd:
    mov al, [tr_n]
    mov [FSBUF + 87], al
    movzx cx, al
    xor bx, bx
    mov di, FSBUF + 88
.st:
    cmp bx, cx
    jae .se
    mov al, [tr_type + bx]
    mov [di], al
    mov al, [tr_kind + bx]
    mov [di + 1], al
    mov al, [tr_id + bx]
    mov [di + 2], al
    mov al, [tr_col + bx]
    mov [di + 3], al
    mov al, [tr_row + bx]
    mov [di + 4], al
    add di, 5
    inc bx
    jmp .st
.se:
    mov word [rw_lba], SET_LBA
    mov bx, FSBUF
    mov ah, 3
    call rw_sector
    pop es
    popa
    ret

; ---- Merhaba ekrani
welcome_screen:
    call ui_prep
    mov ah, 0x5F
    mov bl, 9
    mov si, msg_merhaba
    call ui_ctext
    mov ah, 0xF0
    mov bl, 14
    mov bh, 34
    mov si, msg_btn_ileri
    call ui_textat
.l: call mouse_cursor_update
    call wait_key
    call mouse_hide
    cmp ax, 0xFE00
    je .click
    cmp al, 13
    je .ok
    cmp al, ' '
    je .ok
    jmp .l
.click:
    cmp word [clk_row], 14
    jne .l
    mov ax, [clk_col]
    cmp ax, 34
    jb .l
    cmp ax, 44
    ja .l
.ok:
    ret

; ---- Hesap ekrani: kullanici adi, sifre, atla / kaydet
setup_draw:
    call ui_base
    mov ah, 0x5F
    mov bl, 6
    mov bh, 20
    mov si, msg_lbl_name
    call ui_textat
    mov ah, 0x5F
    mov bl, 10
    mov bh, 20
    mov si, msg_lbl_pass
    call ui_textat
    mov byte [fld_mask], 0
    mov byte [fld_foc], 0
    cmp byte [foc], 0
    jne .a
    mov byte [fld_foc], 1
.a: mov bl, 7
    mov bh, 20
    mov cx, 40
    mov si, in_name
    call draw_field
    mov byte [fld_mask], 1
    mov byte [fld_foc], 0
    cmp byte [foc], 1
    jne .b
    mov byte [fld_foc], 1
.b: mov bl, 11
    mov bh, 20
    mov cx, 40
    mov si, in_pass
    call draw_field
    mov ah, 0xDF
    cmp byte [foc], 2
    jne .c
    mov ah, 0xF0
.c: mov bl, 14
    mov bh, 28
    mov si, msg_btn_atla
    call ui_textat
    mov ah, 0xDF
    cmp byte [foc], 3
    jne .d
    mov ah, 0xF0
.d: mov bl, 14
    mov bh, 44
    mov si, msg_btn_kaydet
    call ui_textat
    ret

setup_screen:
    call ui_prep
    mov byte [in_name], 0
    mov byte [in_nlen], 0
    mov byte [in_pass], 0
    mov byte [in_plen], 0
    mov byte [foc], 0
    call setup_draw
.l: call mouse_cursor_update
    call wait_key
    call mouse_hide
    cmp ax, 0xFE00
    je .click
    cmp al, 13
    je .enter
    cmp al, 9
    je .tab
    cmp al, 8
    je .bs
    cmp al, 32
    jb .l
    cmp al, 126
    ja .l
    cmp byte [foc], 0
    je .addn
    cmp byte [foc], 1
    jne .l
    movzx bx, byte [in_plen]
    cmp bx, 15
    jae .l
    mov [in_pass + bx], al
    inc bx
    mov byte [in_pass + bx], 0
    mov [in_plen], bl
    jmp .redraw
.addn:
    movzx bx, byte [in_nlen]
    cmp bx, 15
    jae .l
    mov [in_name + bx], al
    inc bx
    mov byte [in_name + bx], 0
    mov [in_nlen], bl
.redraw:
    call setup_draw
    jmp .l
.bs:
    cmp byte [foc], 0
    je .bn
    cmp byte [foc], 1
    jne .l
    movzx bx, byte [in_plen]
    test bx, bx
    jz .l
    dec bx
    mov byte [in_pass + bx], 0
    mov [in_plen], bl
    jmp .redraw
.bn:
    movzx bx, byte [in_nlen]
    test bx, bx
    jz .l
    dec bx
    mov byte [in_name + bx], 0
    mov [in_nlen], bl
    jmp .redraw
.tab:
    inc byte [foc]
    and byte [foc], 3
    jmp .redraw
.enter:
    mov al, [foc]
    cmp al, 0
    je .e0
    cmp al, 1
    je .e1
    cmp al, 2
    je .skip
    jmp .save
.e0:
    mov byte [foc], 1
    jmp .redraw
.e1:
    mov byte [foc], 3
    jmp .redraw
.click:
    mov ax, [clk_row]
    mov bx, [clk_col]
    cmp ax, 7
    jne .c2
    cmp bx, 20
    jb .l
    cmp bx, 59
    ja .l
    mov byte [foc], 0
    jmp .redraw
.c2:
    cmp ax, 11
    jne .c3
    cmp bx, 20
    jb .l
    cmp bx, 59
    ja .l
    mov byte [foc], 1
    jmp .redraw
.c3:
    cmp ax, 14
    jne .l
    cmp bx, 28
    jb .c4
    cmp bx, 35
    jbe .skip
.c4:
    cmp bx, 44
    jb .l
    cmp bx, 53
    ja .l
.save:
    cmp byte [in_nlen], 0
    jne .sv
    mov ah, 0x4F
    mov bl, 16
    mov si, msg_err_name
    call ui_ctext
    jmp .l
.sv:
    mov si, in_name
    mov di, u_name
    mov cx, 16
    xor ax, ax
    mov es, ax
    cld
    rep movsb
    mov si, in_pass
    call hash_pass
    mov [u_hash], eax
    mov byte [u_state], 2
    jmp .store
.skip:
    mov byte [u_state], 1
    mov byte [u_name], 0
    mov dword [u_hash], 0
.store:
    call settings_save
    jnc .done
    mov ah, 0x4F
    mov bl, 16
    mov si, msg_err_save
    call ui_ctext
    call wait_key
.done:
    ret

; ---- Kilit ekrani
lock_draw:
    call ui_base
    mov ah, 0x5F
    mov bl, 8
    mov si, u_name
    call ui_ctext
    call lock_field
    mov ah, 0xDF
    mov bl, 14
    mov bh, 30
    mov si, msg_btn_forgot
    call ui_textat
    ret

lock_field:
    mov byte [fld_mask], 1
    mov byte [fld_foc], 1
    mov bl, 10
    mov bh, 28
    mov cx, 24
    mov si, in_pass
    call draw_field
    ret

lock_screen:
    call ui_prep
    mov byte [in_pass], 0
    mov byte [in_plen], 0
    call lock_draw
.l: call mouse_cursor_update
    call wait_key
    call mouse_hide
    cmp ax, 0xFE00
    je .click
    cmp al, 13
    je .enter
    cmp al, 9
    je .forgot
    cmp al, 8
    je .bs
    cmp al, 32
    jb .l
    cmp al, 126
    ja .l
    movzx bx, byte [in_plen]
    cmp bx, 15
    jae .l
    mov [in_pass + bx], al
    inc bx
    mov byte [in_pass + bx], 0
    mov [in_plen], bl
    call lock_field
    jmp .l
.bs:
    movzx bx, byte [in_plen]
    test bx, bx
    jz .l
    dec bx
    mov byte [in_pass + bx], 0
    mov [in_plen], bl
    call lock_field
    jmp .l
.enter:
    mov si, in_pass
    call hash_pass
    cmp eax, [u_hash]
    je .ok
    mov byte [in_pass], 0
    mov byte [in_plen], 0
    call lock_draw
    mov ah, 0x4F
    mov bl, 12
    mov si, msg_wrong
    call ui_ctext
    jmp .l
.click:
    cmp word [clk_row], 14
    jne .l
    mov ax, [clk_col]
    cmp ax, 30
    jb .l
    cmp ax, 48
    ja .l
.forgot:
    call alert_forgot
    call lock_draw
    jmp .l
.ok:
    ret

alert_forgot:                    ; "Unutmasaydin Banane" uyarisi
    mov bl, 9
.r: mov bh, 24
    mov cx, 32
    mov ax, 0x4F20
    call ui_fill
    inc bl
    cmp bl, 14
    jb .r
    mov ah, 0x4F
    mov bl, 11
    mov si, msg_alert
    call ui_ctext
    mov ah, 0x4F
    mov bl, 13
    mov si, msg_alert2
    call ui_ctext
    mov byte [clk_pending], 0
    call mouse_cursor_update
    call wait_key
    call mouse_hide
    ret

; =====================================================
; Paint: sol tus ciz, sag tus sil, ustten renk sec, Temizle, [x] / q ile kapat
; Tuval 74 x 38 piksel (yarim blok karakterlerle), 16 renk
; =====================================================
paint_app:
    call mouse_hide
    call alloc_page
    jnc .ok
    ret
.ok:
    shr eax, 4
    mov [pc_seg], ax
    mov es, ax
    xor di, di
    mov cx, 2812                 ; 74 x 38 piksel, beyaz
    mov al, 15
    cld
    rep stosb
    xor ax, ax
    mov es, ax
    mov byte [pcolor], 0
    mov byte [ptool], 0
    mov word [pstat], 0
    mov byte [pl_down], 0
    mov word [win_title], msg_title_paint
    call ui_window_draw
    mov byte [win_open], 1
    call paint_pal
    call paint_all
    mov byte [clk_pending], 0
    mov byte [ui_close_req], 0
    call mouse_cursor_update
.l: call ui_tick
    cmp byte [ui_close_req], 0
    jne .exit
    mov ah, 1
    int 0x16
    jz .nk
    xor ah, ah
    int 0x16
    cmp al, 'q'
    je .exit
    cmp al, 'Q'
    je .exit
    cmp al, 27
    je .exit
.nk:
    cmp byte [clk_pending], 0
    je .dr
    mov byte [clk_pending], 0
    call paint_click
.dr:
    call paint_draw
    jmp .l
.exit:
    movzx eax, word [pc_seg]
    shl eax, 4
    call free_page
    mov byte [win_open], 0
    ret

paint_pal:                       ; ust cubuk: 16 renk, Silgi, Temizle, Kaydet, Ac, durum
    pusha
    mov bl, 2
    mov bh, 3
    mov cx, 74
    mov ax, 0xDF20
    call ui_fill
    mov bl, 1                    ; baslik cubugunda durum alani
    mov bh, 12
    mov cx, 30
    mov ax, 0xDF20
    call ui_fill
    xor si, si
.sw:
    mov ax, si
    shl al, 4
    or al, 0x0F
    mov ah, al
    mov al, ' '
    mov dx, si
    shl dx, 1
    add dx, 4                    ; sutun = 4 + 2 * renk
    mov bl, 2
    mov bh, dl
    mov cx, 2
    call ui_fill
    movzx cx, byte [pcolor]
    cmp si, cx
    jne .nm
    cmp byte [ptool], 0
    jne .nm
    cmp si, 8
    jb .w
    and ah, 0xF0
.w: mov al, '*'
    mov di, 320
    add di, dx
    add di, dx
    mov [gs:di], ax
.nm:
    inc si
    cmp si, 16
    jb .sw
    mov ah, 0x70
    cmp byte [ptool], 0
    je .b1
    mov ah, 0x4F
.b1:
    mov bl, 2
    mov bh, 37
    mov si, msg_btn_silgi
    call ui_textat
    mov ah, 0x70
    mov bl, 2
    mov bh, 45
    mov si, msg_btn_temizle
    call ui_textat
    mov ah, 0x70
    mov bl, 2
    mov bh, 55
    mov si, msg_btn_kaydet2
    call ui_textat
    mov ah, 0x70
    mov bl, 2
    mov bh, 64
    mov si, msg_btn_ac
    call ui_textat
    mov si, [pstat]
    test si, si
    jz .ns
    mov ah, 0xDA
    mov bl, 1
    mov bh, 12
    call ui_textat
.ns:
    popa
    ret

paint_cell:                      ; BL = satir (0..18), BH = sutun (0..73): iki pikseli bir hucreye ciz
    pusha
    push es
    mov ax, [pc_seg]
    mov es, ax
    movzx ax, bl
    shl ax, 1
    mov dx, 74
    mul dx
    movzx si, bh
    add si, ax
    mov al, [es:si]
    mov ah, [es:si + 74]
    mov cl, ah
    shl cl, 4
    or cl, al
    movzx ax, bl
    add ax, 3
    mov dx, 160
    mul dx
    movzx di, bh
    add di, 3
    shl di, 1
    add di, ax
    mov ah, cl
    mov al, 0xDF
    mov [gs:di], ax
    pop es
    popa
    ret

paint_all:
    pusha
    mov byte [pa_r], 0
.r: mov byte [pa_x], 0
.x: mov bl, [pa_r]
    mov bh, [pa_x]
    call paint_cell
    inc byte [pa_x]
    cmp byte [pa_x], 74
    jb .x
    inc byte [pa_r]
    cmp byte [pa_r], 19
    jb .r
    popa
    ret

paint_set:                       ; BX = x, AX = y, [pl_col] = renk
    pusha
    push es
    cmp bx, 0
    jl .d
    cmp bx, 73
    jg .d
    cmp ax, 0
    jl .d
    cmp ax, 37
    jg .d
    mov cx, ax
    mov dx, 74
    mul dx
    add ax, bx
    mov si, ax
    mov ax, [pc_seg]
    mov es, ax
    mov al, [pl_col]
    mov [es:si], al
    mov ax, cx
    shr ax, 1
    mov bh, bl
    mov bl, al
    call paint_cell
.d: pop es
    popa
    ret

paint_brush:                     ; BX = x, AX = y: kalem 1 piksel, silgi 3x3
    cmp byte [pl_size], 1
    jne .big
    jmp paint_set
.big:
    pusha
    mov cx, ax
    mov si, -1
.j: mov di, -1
.i: mov ax, cx
    add ax, si
    push bx
    add bx, di
    call paint_set
    pop bx
    inc di
    cmp di, 1
    jle .i
    inc si
    cmp si, 1
    jle .j
    popa
    ret

paint_line:                      ; (pl_x0,pl_y0) -> (pl_x1,pl_y1)
    pusha
    mov ax, [pl_x1]
    sub ax, [pl_x0]
    mov [pl_dx], ax
    mov bx, ax
    test bx, bx
    jns .a
    neg bx
.a: mov ax, [pl_y1]
    sub ax, [pl_y0]
    mov [pl_dy], ax
    mov cx, ax
    test cx, cx
    jns .b
    neg cx
.b: cmp cx, bx
    jae .c
    mov cx, bx
.c: mov [pl_st], cx
    xor si, si
.l: mov ax, [pl_dx]
    imul si
    cmp word [pl_st], 0
    je .z1
    idiv word [pl_st]
    jmp .x1
.z1:
    xor ax, ax
.x1:
    add ax, [pl_x0]
    mov bx, ax
    mov ax, [pl_dy]
    imul si
    cmp word [pl_st], 0
    je .z2
    idiv word [pl_st]
    jmp .y1
.z2:
    xor ax, ax
.y1:
    add ax, [pl_y0]
    call paint_brush
    cmp si, [pl_st]
    jae .d
    inc si
    jmp .l
.d: popa
    ret

paint_draw:                      ; tus basili ve imlec tuvaldeyse ciz
    mov al, [mbtn]
    or al, [mbtn_r]
    jnz .dn
    mov byte [pl_down], 0
    ret
.dn:
    mov ax, [mpx]
    shr ax, 3
    sub ax, 3
    mov [pl_x1], ax
    mov ax, [mpy]
    shr ax, 3
    sub ax, 6
    mov [pl_y1], ax
    mov al, [pcolor]
    mov byte [pl_size], 1
    cmp byte [mbtn], 0
    je .er                       ; sadece sag tus: silgi
    cmp byte [ptool], 0
    je .c
.er:
    mov al, 15                   ; silgi: beyaz, 3x3
    mov byte [pl_size], 3
.c: mov [pl_col], al
    call mouse_hide
    cmp byte [pl_down], 0
    jne .ln
    mov ax, [pl_x1]
    mov [pl_x0], ax
    mov ax, [pl_y1]
    mov [pl_y0], ax
.ln:
    call paint_line
    mov ax, [pl_x1]
    mov [pl_x0], ax
    mov ax, [pl_y1]
    mov [pl_y0], ax
    mov byte [pl_down], 1
    call mouse_cursor_update
    ret

paint_click:                     ; renk / silgi / temizle / kaydet / ac
    mov ax, [clk_row]
    cmp ax, 2
    jne .r
    mov bx, [clk_col]
    cmp bx, 4
    jb .r
    cmp bx, 35
    ja .t
    sub bx, 4
    shr bx, 1
    mov [pcolor], bl
    mov byte [ptool], 0
    jmp .upd
.t: cmp bx, 37
    jb .r
    cmp bx, 43
    ja .tm
    xor byte [ptool], 1
    jmp .upd
.tm:
    cmp bx, 45
    jb .r
    cmp bx, 53
    ja .tk
    call mouse_hide
    mov ax, [pc_seg]
    mov es, ax
    xor di, di
    mov cx, 2812
    mov al, 15
    cld
    rep stosb
    xor ax, ax
    mov es, ax
    call paint_all
    call mouse_cursor_update
    ret
.tk:
    cmp bx, 55
    jb .r
    cmp bx, 62
    ja .ta
    call paint_save
    ret
.ta:
    cmp bx, 64
    jb .r
    cmp bx, 67
    ja .r
    call paint_open
    ret
.upd:
    call mouse_hide
    call paint_pal
    call mouse_cursor_update
.r: ret

psave_field:
    mov byte [fld_mask], 0
    mov byte [fld_foc], 1
    mov bl, 10
    mov bh, 20
    mov cx, 40
    mov si, in_name
    call draw_field
    ret

psave_draw:
    pusha
    mov bl, 8
.r: mov bh, 18
    mov cx, 44
    mov ax, 0xDF20
    call ui_fill
    inc bl
    cmp bl, 14
    jb .r
    mov ah, 0xDF
    mov bl, 9
    mov bh, 20
    mov si, msg_lbl_picname
    call ui_textat
    call psave_field
    mov ah, 0xF0
    mov bl, 12
    mov bh, 22
    mov si, msg_btn_kaydet2
    call ui_textat
    mov ah, 0x70
    mov bl, 12
    mov bh, 40
    mov si, msg_btn_iptal
    call ui_textat
    popa
    ret

paint_save:
    call mouse_hide
    mov byte [in_name], 0
    mov byte [in_nlen], 0
    call psave_draw
.l: call mouse_cursor_update
    call wait_key
    call mouse_hide
    cmp ax, 0xFE00
    je .click
    cmp ah, 0xFF
    je .cancel
    cmp al, 13
    je .ok
    cmp al, 27
    je .cancel
    cmp al, 8
    je .bs
    cmp al, 32
    jb .l
    cmp al, 126
    ja .l
    movzx bx, byte [in_nlen]
    cmp bx, 15
    jae .l
    mov [in_name + bx], al
    inc bx
    mov byte [in_name + bx], 0
    mov [in_nlen], bl
    call psave_field
    jmp .l
.bs:
    movzx bx, byte [in_nlen]
    test bx, bx
    jz .l
    dec bx
    mov byte [in_name + bx], 0
    mov [in_nlen], bl
    call psave_field
    jmp .l
.click:
    cmp word [clk_row], 12
    jne .l
    mov ax, [clk_col]
    cmp ax, 22
    jb .c2
    cmp ax, 29
    jbe .ok
.c2:
    cmp ax, 40
    jb .l
    cmp ax, 46
    jbe .cancel
    jmp .l
.ok:
    cmp byte [in_nlen], 0
    je .l
    cmp byte [in_name], '.'
    je .l
    call make_fot_name
    call paint_store
    mov word [pstat], msg_saved
    jnc .done
    mov word [pstat], msg_save_err
    jmp .done
.cancel:
    mov word [pstat], 0
.done:
    call paint_all
    call paint_pal
    call mouse_cursor_update
    ret

set_name:                        ; SI = metin -> [namebuf]
    push si
    push di
    push cx
    push ax
    mov di, namebuf
    mov cx, 27
.l: lodsb
    mov [di], al
    inc di
    test al, al
    jz .d
    loop .l
    mov byte [di], 0
.d: pop ax
    pop cx
    pop di
    pop si
    ret

fs_mkdir_cd:                     ; [namebuf] klasorunu olustur (yoksa) ve icine gir; CF=1 hata
    call fs_find
    jc .new
    cmp word [es:di + 28], 0xFFFF
    jne .err
    mov ax, [es:di + 30]
    mov [cur_dir_seg], ax
    clc
    ret
.new:
    call fs_slot
    jc .err
    call alloc_page
    jc .err
    shr eax, 4
    mov [tmpseg], ax
    mov [es:di + 30], ax
    mov word [es:di + 28], 0xFFFF
    mov si, namebuf
    push di
    mov cx, 28
.cn:
    lodsb
    mov [es:di], al
    inc di
    loop .cn
    pop di
    mov ax, [cur_dir_seg]
    mov [tmpoff], ax
    mov ax, [tmpseg]
    mov es, ax
    xor di, di
    mov cx, 2048
    xor ax, ax
    cld
    rep stosw
    mov byte [es:0], '.'
    mov byte [es:1], '.'
    mov ax, [tmpoff]
    mov [es:30], ax
    mov word [es:28], 0xFFFF
    mov ax, [tmpseg]
    mov [cur_dir_seg], ax
    clc
    ret
.err:
    stc
    ret

fs_put_canvas:                   ; [namebuf] dosyasina tuvali (38 satir x 74 hex karakter) yaz
    call fs_find
    jc .new
    cmp word [es:di + 28], 0xFFFF
    je .err
    jmp .have
.new:
    call fs_slot
    jc .err
    call alloc_page
    jc .err
    shr eax, 4
    mov [es:di + 30], ax
    mov si, namebuf
    push di
    mov cx, 28
.cn:
    lodsb
    mov [es:di], al
    inc di
    loop .cn
    pop di
.have:
    mov [tmpoff], di
    mov ax, [es:di + 30]
    mov es, ax
    xor di, di
    push ds
    mov ax, [pc_seg]
    mov ds, ax
    xor si, si
    mov dx, 38
    cld
.r: mov cx, 74
.c: lodsb
    cmp al, 10
    jb .dg
    add al, 'a' - 10
    jmp .st
.dg:
    add al, '0'
.st:
    stosb
    loop .c
    mov al, 10
    stosb
    dec dx
    jnz .r
    pop ds
    mov ax, [cur_dir_seg]
    mov es, ax
    mov di, [tmpoff]
    mov word [es:di + 28], 2850
    clc
    ret
.err:
    stc
    ret

paint_store:                     ; resmi paint/draw/<ad> olarak kaydet; CF=1 hata
    push ax
    mov ax, [cur_dir_seg]
    push ax
    call fs_ensure
    jc .err
    mov ax, [fs_dir_seg]
    mov [cur_dir_seg], ax
    mov si, s_dir_paint
    call set_name
    call fs_mkdir_cd
    jc .err
    mov si, s_dir_draw
    call set_name
    call fs_mkdir_cd
    jc .err
    mov si, fot_name
    call set_name
    call fs_put_canvas
    jc .err
    call fs_save
    jc .err
    pop ax
    mov [cur_dir_seg], ax
    pop ax
    xor ax, ax
    mov es, ax
    clc
    ret
.err:
    pop ax
    mov [cur_dir_seg], ax
    pop ax
    xor ax, ax
    mov es, ax
    stc
    ret

; ---- Cop kutusu penceresi
trash_draw:
    pusha
    movzx cx, byte [tr_n]
    test cx, cx
    jnz .it
    mov ah, 0x07
    mov bl, 4
    mov bh, 6
    mov si, msg_trash_empty
    call ui_textat
    jmp .btn
.it:
    xor di, di
.l: cmp di, cx
    jae .btn
    mov si, lbl_console
    cmp byte [tr_type + di], 2
    jne .n1
    mov si, lbl_paint
.n1:
    mov bx, tmp_lbl
.cp:
    lodsb
    mov [bx], al
    inc bx
    test al, al
    jnz .cp
    dec bx
    cmp byte [tr_kind + di], 1
    jne .nk
    mov dword [bx], ' (k)'       ; kopyalarin yaninda (k)
    mov byte [bx + 4], 0
.nk:
    mov ah, 0x07
    mov bx, di
    add bl, 3
    mov bh, 6
    mov si, tmp_lbl
    call ui_textat
    mov ah, 0x70
    mov bx, di
    add bl, 3
    mov bh, 30
    mov si, msg_btn_geri
    call ui_textat
    inc di
    jmp .l
.btn:
    mov ah, 0x70
    mov bl, 20
    mov bh, 6
    mov si, msg_btn_bosalt
    call ui_textat
    popa
    ret

trash_click:
    mov ax, [clk_row]
    mov bx, [clk_col]
    cmp ax, 20
    jne .it
    cmp bx, 6
    jb .r
    cmp bx, 13
    ja .r
    mov byte [tr_n], 0
    jmp .redraw
.it:
    sub ax, 3
    jl .r
    movzx cx, byte [tr_n]
    cmp ax, cx
    jae .r
    cmp bx, 30
    jb .r
    cmp bx, 38
    ja .r
    mov si, ax
    call trash_restore
.redraw:
    call mouse_hide
    call clear_screen
    call trash_draw
    call mouse_cursor_update
.r: ret

trash_app:
    call mouse_hide
    mov word [win_title], msg_title_trash
    call ui_window_draw
    mov byte [win_open], 1
    call trash_draw
    mov byte [clk_pending], 0
    mov byte [ui_close_req], 0
    call mouse_cursor_update
.l: call ui_tick
    cmp byte [ui_close_req], 0
    jne .exit
    mov ah, 1
    int 0x16
    jz .nk
    xor ah, ah
    int 0x16
    cmp al, 'q'
    je .exit
    cmp al, 27
    je .exit
.nk:
    cmp byte [clk_pending], 0
    je .l
    mov byte [clk_pending], 0
    call trash_click
    jmp .l
.exit:
    call settings_save           ; cop kutusu ve simge yerlesimi kalici
    mov byte [win_open], 0
    ret

make_fot_name:                   ; [in_name] + ".fot" -> [fot_name]
    push si
    push di
    push bx
    mov si, in_name
    mov di, fot_name
.c: lodsb
    mov [di], al
    inc di
    test al, al
    jnz .c
    dec di
    mov bx, di
    sub bx, fot_name
    cmp bx, 4
    jb .add
    mov bx, di
    sub bx, 4
    cmp dword [bx], '.fot'
    je .d
.add:
    mov dword [di], '.fot'
    mov byte [di + 4], 0
.d: pop bx
    pop di
    pop si
    ret

paint_load:                      ; ES:DI = dizin girisi (.fot) -> tuvale yukle
    cmp word [es:di + 28], 2850
    jne .r
    mov ax, [es:di + 30]
    mov bx, [pc_seg]
    push ds
    mov ds, ax
    mov es, bx
    xor si, si
    xor di, di
    mov dx, 38
    cld
.l: mov cx, 74
.c: lodsb
    cmp al, 'a'
    jb .n
    sub al, 'a' - 10
    jmp .s
.n: sub al, '0'
.s: cmp al, 15
    jbe .w
    mov al, 15
.w: stosb
    loop .c
    lodsb
    dec dx
    jnz .l
    pop ds
.r: xor ax, ax
    mov es, ax
    ret

po_draw:
    pusha
    mov bl, 4
.r: mov bh, 16
    mov cx, 48
    mov ax, 0xDF20
    call ui_fill
    inc bl
    cmp bl, 18
    jb .r
    mov ah, 0xDF
    mov bl, 4
    mov bh, 18
    mov si, msg_title_open
    call ui_textat
    cmp word [op_n], 0
    jne .it
    mov ah, 0xDF
    mov bl, 7
    mov bh, 18
    mov si, msg_no_pics
    call ui_textat
    jmp .btn
.it:
    xor si, si
.l: cmp si, [op_n]
    jae .btn
    push si
    mov bx, si
    shl bx, 1
    mov di, [op_ent + bx]
    mov ax, [op_dir]
    mov es, ax
    mov bx, tmp_lbl
    mov ax, si
    add al, '1'
    mov [bx], al
    mov byte [bx + 1], ' '
    mov byte [bx + 2], ' '
    add bx, 3
.cn:
    mov al, [es:di]
    mov [bx], al
    inc bx
    inc di
    test al, al
    jnz .cn
    xor ax, ax
    mov es, ax
    pop si
    mov ah, 0x70
    mov bx, si
    add bl, 6
    mov bh, 18
    push si
    mov si, tmp_lbl
    call ui_textat
    pop si
    inc si
    jmp .l
.btn:
    mov ah, 0x70
    mov bl, 16
    mov bh, 20
    mov si, msg_btn_iptal
    call ui_textat
    popa
    ret

paint_open:                      ; paint/draw klasorundeki .fot resimlerini listele, secileni ac
    call mouse_hide
    mov word [op_n], 0
    mov ax, [cur_dir_seg]
    push ax
    cmp word [fs_dir_seg], 0
    je .dlg
    mov ax, [fs_dir_seg]
    mov [cur_dir_seg], ax
    mov si, s_dir_paint
    call set_name
    call fs_find
    jc .dlg
    cmp word [es:di + 28], 0xFFFF
    jne .dlg
    mov ax, [es:di + 30]
    mov [cur_dir_seg], ax
    mov si, s_dir_draw
    call set_name
    call fs_find
    jc .dlg
    cmp word [es:di + 28], 0xFFFF
    jne .dlg
    mov ax, [es:di + 30]
    mov [op_dir], ax
    mov es, ax
    xor di, di
    mov cx, 128
.sc:
    cmp byte [es:di], 0
    je .nx
    cmp word [es:di + 28], 0xFFFF
    je .nx
    xor bx, bx
.len:
    cmp byte [es:di + bx], 0
    je .le
    inc bx
    cmp bx, 28
    jb .len
.le:
    cmp bx, 5
    jb .nx
    mov si, di
    add si, bx
    sub si, 4
    cmp dword [es:si], '.fot'
    jne .nx
    mov bx, [op_n]
    cmp bx, 9
    jae .nx
    shl bx, 1
    mov [op_ent + bx], di
    inc word [op_n]
.nx:
    add di, 32
    dec cx
    jnz .sc
.dlg:
    xor ax, ax
    mov es, ax
    call po_draw
.l: call mouse_cursor_update
    call wait_key
    call mouse_hide
    cmp ax, 0xFE00
    je .click
    cmp ah, 0xFF
    je .cancel
    cmp al, 27
    je .cancel
    cmp al, '1'
    jb .l
    cmp al, '9'
    ja .l
    sub al, '1'
    movzx bx, al
    jmp .pick
.click:
    mov ax, [clk_row]
    cmp ax, 16
    jne .r1
    mov bx, [clk_col]
    cmp bx, 20
    jb .l
    cmp bx, 26
    ja .l
    jmp .cancel
.r1:
    sub ax, 6
    jl .l
    cmp ax, [op_n]
    jae .l
    mov bx, [clk_col]
    cmp bx, 18
    jb .l
    cmp bx, 62
    ja .l
    mov bx, ax
.pick:
    cmp bx, [op_n]
    jae .l
    shl bx, 1
    mov di, [op_ent + bx]
    mov ax, [op_dir]
    mov es, ax
    call paint_load
    mov word [pstat], msg_opened
    jmp .done
.cancel:
    mov word [pstat], 0
.done:
    pop ax
    mov [cur_dir_seg], ax
    xor ax, ax
    mov es, ax
    call paint_all
    call paint_pal
    call mouse_cursor_update
    ret

; ---- Numarali hata: AL = hata kodu -> "Error N: aciklama"
error:
    pushad
    mov [last_err], al
    mov byte [attr], 0x0C
    mov si, msg_error
    call print
    movzx eax, byte [last_err]
    call print_dec
    mov si, msg_colon
    call print
    movzx bx, byte [last_err]
    shl bx, 1
    mov si, [err_table + bx]
    call print
    mov byte [attr], 0x07
    popad
    ret

cmd_err:                         ; son hata kodu
    mov byte [attr], 0x07
    mov si, msg_lasterr
    call print
    movzx eax, byte [last_err]
    call print_dec
    mov si, msg_dash
    call print
    movzx bx, byte [last_err]
    shl bx, 1
    mov si, [err_table + bx]
    call print
    ret

cmd_errors:                      ; tum hata kodlari
    mov bx, 1
.l: cmp bx, ERR_MAX
    ja .d
    mov byte [attr], 0x0B
    movzx eax, bx
    call print_dec
    mov byte [attr], 0x07
    mov si, msg_dash
    call print
    push bx
    shl bx, 1
    mov si, [err_table + bx]
    call print
    pop bx
    inc bx
    jmp .l
.d: ret

; =====================================================
; Hesap modu (x87 FPU, 80 bit): kesir, buyuk sayi, parantez
;   + (veya =)   - cikarma   * x carpma   / bolme   % m mod
;   ( ) veya [ ] parantez    ! (veya n) = ifadenin isaretini cevirir
;   ondalik: . veya ,        Bos satir = cikis
; =====================================================
%macro FSPILL 0
    sub sp, 10
    mov bp, sp
    fstp tword [bp]
%endmacro
%macro FRELOAD 0
    mov bp, sp
    fld tword [bp]
    add sp, 10
%endmacro

cmd_calc:
    mov byte [attr], 0x07
    mov si, msg_calc_info
    call print
.loop:
    mov byte [attr], 0x0E
    mov si, msg_calc_prompt
    call print
    mov byte [attr], 0x07
    call read_line
    cmp byte [CMDBUF], 0
    je .exit
    call calc_eval
    jc .err
    mov byte [attr], 0x0B
    mov si, msg_eq
    call print
    call print_fp
    mov al, 10
    call putc
    jmp .loop
.err:
    call error
    jmp .loop
.exit:
    ret

; CMDBUF ifadesini hesapla -> ST0, CF=1 hata (AL = hata kodu)
calc_eval:
    push si
    mov si, CMDBUF
    mov [calc_sp], sp
    fninit
    call parse_expr
    call skip_sp
    cmp byte [si], 0
    je .e1
    jmp calc_syntax
.e1:
    fld st0
    fabs
    fcomp qword [fp_big]
    fstsw ax
    sahf
    jb .e2
    jmp calc_over
.e2:
    clc
    pop si
    ret
calc_syntax:
    mov al, ERR_SYNTAX
    jmp calc_fail
calc_div0:
    mov al, ERR_DIV0
    jmp calc_fail
calc_over:
    mov al, ERR_OVERFLOW
calc_fail:
    mov sp, [calc_sp]
    fninit
    stc
    pop si
    ret

skip_sp:
    cmp byte [si], ' '
    jne .d
    inc si
    jmp skip_sp
.d: ret

chk_zero:                        ; ST0 = bolen, sifirsa hata
    ftst
    fstsw ax
    sahf
    jne .ok
    jmp calc_div0
.ok:
    ret

; ifade := terim { (+|-) terim }
parse_expr:
    call parse_term
.l: call skip_sp
    mov al, [si]
    cmp al, '+'
    je .add
    cmp al, '='
    je .add
    cmp al, '-'
    je .sub
    ret
.add:
    inc si
    FSPILL
    call parse_term
    FRELOAD
    faddp st1, st0
    jmp .l
.sub:
    inc si
    FSPILL
    call parse_term
    FRELOAD                      ; ST0 = onceki, ST1 = sag taraf
    fsub st0, st1
    fxch st1
    fstp st0
    jmp .l

; terim := faktor { (*|/|%) faktor }
parse_term:
    call parse_factor
.l: call skip_sp
    mov al, [si]
    cmp al, '*'
    je .mul
    cmp al, 'x'
    je .mul
    cmp al, 'X'
    je .mul
    cmp al, 0x80
    je .mul
    cmp al, '/'
    je .div
    cmp al, 0xF6
    je .div
    cmp al, '%'
    je .mod
    cmp al, 'm'
    je .mod
    cmp al, 'M'
    je .mod
    ret
.mul:
    inc si
    FSPILL
    call parse_factor
    FRELOAD
    fmulp st1, st0
    jmp .l
.div:
    inc si
    FSPILL
    call parse_factor
    call chk_zero
    FRELOAD
    fdiv st0, st1
    fxch st1
    fstp st0
    jmp .l
.mod:
    inc si
    FSPILL
    call parse_factor
    call chk_zero
    FRELOAD
.p: fprem
    fstsw ax
    test ah, 4
    jnz .p
    fxch st1
    fstp st0
    jmp .l

; faktor := [-|+] faktor | ! ifade | ( ifade ) | sayi
parse_factor:
    call skip_sp
    mov al, [si]
    cmp al, '-'
    je .neg
    cmp al, '+'
    je .pos
    cmp al, '='
    je .pos
    cmp al, '!'
    je .flip
    cmp al, 'n'
    je .flip
    cmp al, 'N'
    je .flip
    cmp al, '('
    je .par
    cmp al, '['
    je .par
    jmp parse_num
.neg:
    inc si
    call parse_factor
    fchs
    ret
.pos:
    inc si
    jmp parse_factor
.flip:
    inc si
    call parse_expr
    fchs
    ret
.par:
    inc si
    call parse_expr
    call skip_sp
    mov al, [si]
    cmp al, ')'
    je .cl
    cmp al, ']'
    je .cl
    test al, al
    jz .ret
    jmp calc_syntax
.cl:
    inc si
.ret:
    ret

; sayi: rakamlar [. rakamlar]  -> ST0
parse_num:
    push ax
    push cx
    fldz
    xor cx, cx
    mov byte [pn_dec], 0
    mov word [pn_n], 0
.l: mov al, [si]
    cmp al, '.'
    je .dot
    cmp al, ','
    je .dot
    sub al, '0'
    cmp al, 9
    ja .end
    xor ah, ah
    mov [tmp16], ax
    fmul dword [fp_10]
    fild word [tmp16]
    faddp st1, st0
    inc cx
    inc si
    cmp byte [pn_dec], 0
    je .l
    inc word [pn_n]
    jmp .l
.dot:
    cmp byte [pn_dec], 0
    jne .end
    mov byte [pn_dec], 1
    inc si
    jmp .l
.end:
    test cx, cx
    jnz .have
    jmp calc_syntax
.have:
    mov cx, [pn_n]
.dv:
    test cx, cx
    jz .d
    fdiv dword [fp_10]
    dec cx
    jmp .dv
.d: pop cx
    pop ax
    ret

; ST0 degerini yazdir (en fazla 6 ondalik, sondaki sifirlar atilir)
print_fp:
    pusha
    mov byte [pf_neg], 0
    ftst
    fstsw ax
    sahf
    jae .abs
    mov byte [pf_neg], 1
    fchs
.abs:
    fld st0
    fldcw [cw_trunc]
    frndint                      ; ST0 = tam kisim, ST1 = deger
    fldcw [cw_near]
    fxch
    fsub st0, st1                ; ST0 = kesir
    fmul dword [fp_1e6]
    fistp dword [pf_frac]
    cmp dword [pf_frac], 1000000
    jne .nc
    fld1
    faddp st1, st0
    mov dword [pf_frac], 0
.nc:
    fbstp tword [bcd_buf]
    cmp byte [pf_neg], 0
    je .num
    cmp dword [pf_frac], 0
    jne .sg
    mov cx, 9
    mov bx, bcd_buf
.z: cmp byte [bx], 0
    jne .sg
    inc bx
    loop .z
    jmp .num
.sg:
    mov al, '-'
    call putc
.num:
    mov bx, 8
    xor cx, cx
.l: mov al, [bcd_buf + bx]
    mov ah, al
    shr al, 4
    call .dig
    mov al, ah
    and al, 15
    call .dig
    dec bx
    jns .l
    test cx, cx
    jnz .fr
    mov al, '0'
    call putc
.fr:
    cmp dword [pf_frac], 0
    je .done
    mov al, '.'
    call putc
    mov eax, [pf_frac]
    mov [fr_rest], eax
    mov dword [fr_div], 100000
.fl:
    mov eax, [fr_rest]
    xor edx, edx
    mov ecx, [fr_div]
    div ecx
    mov [fr_rest], edx
    add al, '0'
    call putc
    cmp dword [fr_rest], 0
    je .done
    mov eax, [fr_div]
    xor edx, edx
    mov ecx, 10
    div ecx
    mov [fr_div], eax
    jmp .fl
.done:
    popa
    ret
.dig:
    test cx, cx
    jnz .p
    test al, al
    jz .sk
    mov cx, 1
.p: add al, '0'
    call putc
.sk:
    ret

cmd_halt:
    mov byte [attr], 0x0C
    mov si, msg_halt
    call print
    cli
.h: hlt
    jmp .h

; ---- Free / Used / Reserved yazdir
show_ram:
    mov byte [attr], 0x07
    mov si, msg_free
    call print
    call count_free
    shl eax, 2
    call print_kb

    mov byte [attr], 0x07
    mov si, msg_used
    call print
    mov eax, [used_pages]
    shl eax, 2
    call print_kb

    mov byte [attr], 0x07
    mov si, msg_res
    call print
    mov eax, [reserved_kb]
    call print_kb
    ret

; ---- ~3 saniye bekle (BIOS tick: 18.2/sn -> 55 tick)
wait_3s:
    push ax
    push bx
    push cx
    push dx
    xor ax, ax
    int 0x1A
    mov bx, dx
.w: xor ax, ax
    int 0x1A
    mov ax, dx
    sub ax, bx
    cmp ax, 55
    jb .w
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---- Ekrani temizle, imleci basa al
clear_screen:                    ; goruntu alanini (viewport) temizle
    pusha
    push es
    mov byte [cur_valid], 0
    mov ax, 0xB800
    mov es, ax
    mov ax, [vp_y0]
    mov cx, 160
    mul cx
    mov di, [vp_x0]
    shl di, 1
    add di, ax
    mov [cursor], di
    mov bp, [vp_x1]
    sub bp, [vp_x0]
    inc bp
    mov bx, [vp_y1]
    sub bx, [vp_y0]
    inc bx
    mov dl, [scr_attr]
    cld
.r: mov ah, dl
    mov al, ' '
    mov cx, bp
    push di
    rep stosw
    pop di
    add di, 160
    dec bx
    jnz .r
    pop es
    popa
    call set_hwcursor
    ret

; ---- Donanim imlecini [cursor] konumuna tasi
set_hwcursor:
    pusha
    mov ax, [cursor]
    shr ax, 1
    mov bx, ax
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    popa
    ret

; =====================================================
; Bellek yoneticisi (sayfa bitmap'i)
; =====================================================
handle_entry:
    pushad
    push es
    mov edx, [E820BUF + 0]
    mov eax, [E820BUF + 8]
    cmp dword [E820BUF + 16], 1
    jne .res
    cmp dword [E820BUF + 4], 0
    jne .ret
    cmp dword [E820BUF + 12], 0
    jne .clamp
    mov ecx, edx
    add ecx, eax
    jnc .okend
.clamp:
    mov ecx, 0xFFFFFFFF
.okend:
    add edx, 4095
    jc .ret
    shr edx, 12
    shr ecx, 12
    cmp ecx, MAXPAGES
    jbe .c2
    mov ecx, MAXPAGES
.c2:
    mov ax, BITMAP_SEG
    mov es, ax
.cl:
    cmp edx, ecx
    jae .ret
    call clear_bit
    inc edx
    jmp .cl
.res:
    shr eax, 10
    add [reserved_kb], eax
.ret:
    pop es
    popad
    ret

clear_bit:
    push eax
    push ebx
    push ecx
    mov ebx, edx
    shr ebx, 3
    mov cl, dl
    and cl, 7
    mov al, 1
    shl al, cl
    not al
    and [es:bx], al
    pop ecx
    pop ebx
    pop eax
    ret

lock_range:
    push eax
    push ebx
    push ecx
    push es
    mov ax, BITMAP_SEG
    mov es, ax
.l: test esi, esi
    jz .d
    mov ebx, edx
    shr ebx, 3
    mov cl, dl
    and cl, 7
    mov al, 1
    shl al, cl
    test [es:bx], al
    jnz .skip
    or [es:bx], al
    inc dword [used_pages]
.skip:
    inc edx
    dec esi
    jmp .l
.d: pop es
    pop ecx
    pop ebx
    pop eax
    ret

count_free:
    push ebx
    push ecx
    push edx
    push edi
    push es
    mov ax, BITMAP_SEG
    mov es, ax
    xor di, di
    xor edx, edx
    mov cx, BITMAP_BYTES
.b: mov al, [es:di]
    not al
    mov bl, 8
.bit:
    shr al, 1
    adc edx, 0
    dec bl
    jnz .bit
    inc di
    loop .b
    mov eax, edx
    pop es
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; Ekran yazdirma
; =====================================================
print_kb:
    mov byte [attr], 0x0B
    call print_dec
    mov si, msg_kb
    call print
    ret

print_dec:                       ; EAX = sayi
    pushad
    mov di, numend
    mov ecx, 10
.l: xor edx, edx
    div ecx
    add dl, '0'
    dec di
    mov [di], dl
    test eax, eax
    jnz .l
    mov si, di
    call print
    popad
    ret

print:                           ; SI = string (SI sonda 0'in arkasinda kalir)
    push ax
.l: lodsb
    test al, al
    jz .d
    call putc
    jmp .l
.d: pop ax
    ret

putc:                            ; AL = karakter, [attr] rengi (viewport icinde)
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, [cursor]
    cmp al, 10
    je .nl
    mov ah, [attr]
    test ah, 0xF0                ; ozel arka plani olan renk aynen yazilir
    jnz .st
    mov bl, ah
    cmp bl, 7                    ; varsayilan metin rengi -> secilen metin rengi
    jne .nb
    mov bl, [fg_color]
.nb:
    mov ah, [bg_hi]              ; secilen arka plan
    or ah, bl
.st:
    mov [gs:di], ax
    mov ax, di
    xor dx, dx
    mov cx, 160
    div cx                       ; AX = satir, DX = sutun * 2
    shr dx, 1
    mov bx, dx
    inc bx                       ; sonraki sutun
    cmp bx, [vp_x1]
    jbe .p
    mov bx, [vp_x0]              ; sag kenara geldi: alt satira sar
    inc ax
    jmp .p
.nl:
    mov ax, di
    xor dx, dx
    mov cx, 160
    div cx
    inc ax
    mov bx, [vp_x0]
.p: call vp_place
    mov [cursor], di
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

vp_place:                        ; AX = satir, BX = sutun -> DI (gerekirse kaydirir)
    cmp ax, [vp_y1]
    jbe .ok
    push bx
    call scroll
    pop bx
    mov ax, [vp_y1]
.ok:
    mov cx, 160
    mul cx
    shl bx, 1
    add ax, bx
    mov di, ax
    ret

scroll:                          ; goruntu alanini 1 satir yukari kaydir
    pusha
    push ds
    push es
    mov ax, [vp_y0]
    mov cx, 160
    mul cx
    mov di, [vp_x0]
    shl di, 1
    add di, ax
    mov bp, [vp_x1]
    sub bp, [vp_x0]
    inc bp                       ; genislik
    mov cx, [vp_y1]
    sub cx, [vp_y0]              ; kaydirilacak satir
    mov dl, [scr_attr]
    mov si, di
    add si, 160
    mov ax, 0xB800
    mov ds, ax
    mov es, ax
    cld
    test cx, cx
    jz .last
.r: push cx
    push si
    push di
    mov cx, bp
    rep movsw
    pop di
    pop si
    pop cx
    add di, 160
    add si, 160
    loop .r
.last:
    mov ah, dl
    mov al, ' '
    mov cx, bp
    rep stosw
    pop es
    pop ds
    popa
    ret

cursor_back:                     ; imleci 1 hucre geri al ve sil (viewport icinde)
    push ax
    push bx
    push cx
    push dx
    mov ax, [cursor]
    xor dx, dx
    mov cx, 160
    div cx
    shr dx, 1
    mov bx, dx
    cmp bx, [vp_x0]
    ja .same
    cmp ax, [vp_y0]
    jbe .done
    dec ax
    mov bx, [vp_x1]
    jmp .set
.same:
    dec bx
.set:
    mul cx
    shl bx, 1
    add ax, bx
    mov [cursor], ax
    mov bx, ax
    mov ah, [scr_attr]
    mov al, ' '
    mov [gs:bx], ax
.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =====================================================
; Veri
; =====================================================
msg_boot   db 'Booting DavOS...', 10, 0
msg_free   db 'Free RAM: ', 0
msg_used   db 'Used RAM: ', 0
msg_res    db 'Reserved RAM: ', 0
msg_kb     db ' KB', 10, 0
msg_lock   db 'Locking Pages for Kernel...', 10, 0
msg_arrow  db ' > ', 0
msg_prompt db 'local_user', 0
msg_dollar db '$ ', 0
msg_ver_pre  db 'DavOS v', 0
msg_calc_prompt db 'hesap> ', 0
msg_eq      db '= ', 0
msg_ui_icon db ' >_ ', 0
msg_win_title db 'Konsol', 0
msg_title_paint db 'Paint', 0
msg_title_trash db 0x8B, 0x94, 'p Kutusu', 0
msg_trash_empty db 0x8B, 0x94, 'p kutusu bo', 0x89, 0
msg_btn_geri db ' Geri al ', 0
msg_btn_bosalt db ' Bo', 0x89, 'alt ', 0
msg_btn_silgi db ' Silgi ', 0
msg_btn_kaydet2 db ' Kaydet ', 0
msg_btn_iptal db ' ', 0x8C, 'ptal ', 0
msg_lbl_picname db 'Resim ad', 0x88, ':', 0
msg_saved   db 'Kaydedildi', 0
msg_btn_ac  db ' A', 0x8D, ' ', 0
msg_title_open db 'Resim a', 0x8D, ' (1-9)', 0
msg_no_pics db 'Kay', 0x88, 'tl', 0x88, ' resim yok', 0
msg_opened  db 'A', 0x8D, 0x88, 'ld', 0x88, 0
msg_save_err db 'Hata', 0
s_dir_paint db 'paint', 0
s_dir_draw  db 'draw', 0
bg_light    db 0,0,0,0,0,1,0,1,0,0,1,1,1,0,1,1
msg_btn_temizle db ' Temizle ', 0
msg_m_tasi  db ' Ta', 0x89, 0x88, 0
msg_m_kopya db ' Kopyala ve ta', 0x89, 0x88, 0
ico_console:
    dw 0x0720, 0x0720, 0x0720, 0x0720, 0x0720, 0x0720
    dw 0x0720, 0x0A3E, 0x0A5F, 0x0720, 0x0720, 0x0720
    dw 0x0720, 0x0720, 0x0720, 0x0720, 0x0720, 0x0720
ico_paint:
    dw 0x4F20, 0xEF20, 0x2F20, 0xBF20, 0x9F20, 0xCF20
    dw 0xCF20, 0x3F20, 0x1F20, 0xAF20, 0x6F20, 0xEF20
    dw 0xFF20, 0x7F20, 0x8F20, 0x4F20, 0x2F20, 0x9F20
ico_trash:
    dw 0x7020, 0x7020, 0x7020, 0x7020, 0x7020, 0x7020
    dw 0x8720, 0x87B3, 0x8720, 0x8720, 0x87B3, 0x8720
    dw 0x8720, 0x87B3, 0x8720, 0x8720, 0x87B3, 0x8720
lbl_console db 'Konsol', 0
lbl_trash   db 0x8B, 0x94, 'p', 0
str_dot     db 0x07, 0
lbl_paint   db 'Paint', 0
msg_merhaba db 'M e r h a b a', 0
msg_btn_ileri db '   ileri   ', 0
msg_btn_atla db '  atla  ', 0
msg_btn_kaydet db '  kaydet  ', 0
msg_btn_forgot db '  ', 0x8A, 'ifreyi unuttum  ', 0
msg_lbl_name db 'Bilgisayar Kullan', 0x88, 'c', 0x88, ' ismi', 0
msg_lbl_pass db 'Giri', 0x89, ' ', 0x8A, 'ifresi', 0
msg_err_name db 'Kullan', 0x88, 'c', 0x88, ' ismi bo', 0x89, ' olamaz', 0
msg_err_save db 'Ayarlar diske yaz', 0x88, 'lamad', 0x88, ' (bir tu', 0x89, 'a bas)', 0
msg_wrong   db 'Yanl', 0x88, 0x89, ' ', 0x89, 'ifre', 0
msg_alert   db 'Unutmasayd', 0x88, 'n Banane', 0
msg_alert2  db '(bir tusa bas)', 0
msg_win_x   db '[x]', 0
msg_usage_time db 'Kullanim: time -d | -t | -m | -h', 10, 0
msg_usage_file2 db 'Kullanim: file -h', 10, 0
msg_usage_adam db 'Kullanim: adam gibi adam', 10, 0
msg_ag_title db 'TURKIYE - AGRI (plaka 04)', 10, 10, 0
msg_ag_l1   db 10, '  # Agri', 0
msg_ag_l2   db '    + Istanbul, Ankara, Izmir', 10, 0
msg_ag_l3   db "  Agri Dagi 5137 m: Turkiye'nin en yuksek dagi", 10, 0
msg_col_bg  db 'Arka plan: ', 0
msg_col_fg  db 'Yazi:      ', 0
msg_col_ex  db 'Ornek: color a2 | color a | color 5 | color reset', 10, 0
msg_usage_color db 'Kullanim: color a2 | color a | color 5 | color reset', 10, 0
msg_xo_title db 'XOX - ', 0
s_lv0       db 'Iki kisilik', 10, 10, 0
s_lv1       db 'Kolay', 10, 10, 0
s_lv2       db 'Orta', 10, 10, 0
s_lv3       db 'Zor', 10, 10, 0
lvl_names   dw s_lv0, s_lv1, s_lv2, s_lv3
msg_xo_menu db 'XOX', 10, 10, '  1 - Kolay', 10, '  2 - Orta', 10, '  3 - Zor', 10, '  4 - Iki kisilik', 10, 10, 'Sec (1-4), q = cik', 10, 0
msg_xo_ind  db '    ', 0
msg_xo_sep  db '    ---+---+---', 10, 0
msg_xo_turn db 10, 'Sira: ', 0
msg_xo_help db ' - hucre sec (1-9), q = cik', 10, 0
msg_xo_you  db 10, 'Kazandin!', 10, 0
msg_xo_cpu  db 10, 'Bilgisayar kazandi.', 10, 0
msg_xo_xw   db 10, 'X kazandi!', 10, 0
msg_xo_ow   db 10, 'O kazandi!', 10, 0
msg_xo_draw db 10, 'Berabere.', 10, 0
msg_xo_again db 'Tekrar: bir tusa bas, q = cik', 10, 0
msg_calc_info db 'Hesap: + - * x / % ( ) [ ] ! kesir . ,   Bos satir = cikis', 10, 0
msg_ver_tail db ' (x86 16-bit real mode)', 10, 0
msg_halt   db 'Sistem durduruldu.', 10, 0
msg_unk2   db ' bilinmiyor. Komutlar icin help yaz.', 10, 0

s_help     db 'help', 0
s_q        db '?', 0
s_sym      db 'sym', 0
s_hesap    db 'hesap', 0
s_xox      db 'xox', 0
s_color    db 'color', 0
s_reset    db 'reset', 0
s_kolay    db 'kolay', 0
s_orta     db 'orta', 0
s_zor      db 'zor', 0
s_agri     db 'agri', 0
s_adam     db 'adam', 0
s_gibiadam db 'gibi adam', 0
s_mkdir    db 'mkdir', 0
s_cd       db 'cd', 0
s_pwd      db 'pwd', 0
s_calc     db 'calc', 0
s_clear    db 'clear', 0
s_ram      db 'ram', 0
s_ver      db 'ver', 0
s_reboot   db 'reboot', 0
s_halt     db 'halt', 0
s_exit     db 'exit', 0
s_time     db 'time', 0
s_file     db 'file', 0
s_neofetch db 'neofetch', 0
s_echo     db 'echo', 0
s_ls       db 'ls', 0
s_cat      db 'cat', 0
s_write    db 'write', 0
s_rm       db 'rm', 0
s_alloc    db 'alloc', 0
s_free     db 'free', 0
s_heap     db 'heap', 0
s_err      db 'err', 0
s_errors   db 'errors', 0

cmd_table:
    dw s_help,   cmd_help
    dw s_q,      cmd_help
    dw s_sym,    cmd_sym
    dw s_hesap,  cmd_calc
    dw s_xox,    cmd_xox
    dw s_adam,   cmd_adam
    dw s_agri,   cmd_agri
    dw s_color,  cmd_color
    dw s_mkdir,  cmd_mkdir
    dw s_cd,     cmd_cd
    dw s_pwd,    cmd_pwd
    dw s_calc,   cmd_calc
    dw s_clear,  cmd_clear
    dw s_ram,    cmd_ram
    dw s_ver,    cmd_ver
    dw s_reboot, cmd_reboot
    dw s_halt,   cmd_halt
    dw s_exit,   cmd_exit
    dw s_time,   cmd_time
    dw s_file,   cmd_file
    dw s_neofetch, cmd_neofetch
    dw s_echo,   cmd_echo
    dw s_ls,     cmd_ls
    dw s_cat,    cmd_cat
    dw s_write,  cmd_write
    dw s_rm,     cmd_rm
    dw s_alloc,  cmd_alloc
    dw s_free,   cmd_free
    dw s_heap,   cmd_heap
    dw s_err,    cmd_err
    dw s_errors, cmd_errors
    dw 0

help_table:
    db '  help     ', 0, '- Komutlari listeler', 10, 0
    db '  clear    ', 0, '- Ekrani temizler', 10, 0
    db '  ram      ', 0, '- Bellek durumu', 10, 0
    db '  ver      ', 0, '- DavOS surumu', 10, 0
    db '  neofetch ', 0, '- Logo ile sistem bilgisi', 10, 0
    db '  echo     ', 0, '- echo metin: metni basar', 10, 0
    db '  time     ', 0, '- Zaman bilgisi (-h ile detayli bilgi)', 10, 0
    db '  file     ', 0, '- Dosya komutlari (-h ile detayli bilgi)', 10, 0
    db '  heap     ', 0, '- heap | alloc | free N: heap bellek', 10, 0
    db '  err      ', 0, '- err | errors: hata kodlari', 10, 0
    db '  hesap    ', 0, '- Hesap makinesi (bos satir = cikis)', 10, 0
    db '  sym      ', 0, '- :isim: semboller, ` tusu: palet', 10, 0
    db '  xox      ', 0, '- XOX: xox | kolay | orta | zor | 2', 10, 0
    db '  color    ', 0, '- color a2 | a | 5 | reset', 10, 0
    db '  agri     ', 0, '- Turkiye haritasinda Agri', 10, 0
    db '  adam     ', 0, '- adam gibi adam', 10, 0
    db '  exit     ', 0, '- Konsolu kapatir', 10, 0
    db '  reboot   ', 0, '- Yeniden baslatir', 10, 0
    db '  halt     ', 0, '- Islemciyi durdurur', 10, 0
    db 0

time_table:
    db '  time -d  ', 0, '- Tarih (GG.AA.YYYY)', 10, 0
    db '  time -t  ', 0, '- Saat (SS:DD:SN)', 10, 0
    db '  time -m  ', 0, '- Tarih ve saat birlikte', 10, 0
    db '  time -h  ', 0, '- Bu yardimi gosterir', 10, 0
    db 0

file_table:
    db '  ls       ', 0, '- Dosya ve klasorleri listeler', 10, 0
    db '  write    ', 0, '- write dosya metin: dosya olustur/yaz', 10, 0
    db '  cat      ', 0, '- cat dosya: dosyayi gosterir', 10, 0
    db '  rm       ', 0, '- rm ad: dosya veya bos klasoru siler', 10, 0
    db '  mkdir    ', 0, '- mkdir ad: klasor olusturur', 10, 0
    db '  cd       ', 0, '- cd ad | cd .. | cd /: klasor degistirir', 10, 0
    db '  pwd      ', 0, '- Bulundugun klasoru gosterir', 10, 0
    db 0

; ---- neofetch verisi
%macro LG 1+
%%a: db %1
    times 26 - ($ - %%a) db ' '
    db 0
%endmacro

logo_table:                      ; D harfi + ortasinda Davud'un yildizi (ici bos)
    LG '   ############'
    LG '   ##############'
    LG '   ####        ####'
    LG '   ####    ', 0xDC, 0xDF, 0xDC, '   ####'
    LG '   #### ', 0xDC, 0xDC, 0xDC, 0xDB, 0xDC, 0xDB, 0xDC, 0xDC, 0xDC, ' ####'
    LG '   #### ', 0xDF, 0xDC, 0xDF, '   ', 0xDF, 0xDC, 0xDF, ' ####'
    LG '   #### ', 0xDC, 0xDF, 0xDC, '   ', 0xDC, 0xDF, 0xDC, ' ####'
    LG '   #### ', 0xDF, 0xDF, 0xDF, 0xDB, 0xDF, 0xDB, 0xDF, 0xDF, 0xDF, ' ####'
    LG '   ####    ', 0xDF, 0xDC, 0xDF, '   ####'
    LG '   ####        ####'
    LG '   ##############'
    LG '   ############'
    LG ''

nf_text:
    db 'local_user@DavOS', 10, 0, 0
    db '----------------', 10, 0, 0
    db 'OS: ', 0, 'DavOS x86 (real mode)', 10, 0
    db 'Host: ', 0
    db 'Kernel: ', 0
    db 'Uptime: ', 0
    db 'Shell: ', 0, 'DavShell', 10, 0
    db 'Resolution: ', 0, '80x25 text', 10, 0
    db 'Terminal: ', 0, 'VGA text mode', 10, 0
    db 'CPU: ', 0
    db 'Memory: ', 0

block_attrs db 0x40, 0x20, 0x60, 0x10, 0x50, 0x30, 0x70, 0
msg_block   db '    ', 0
msg_secs    db ' secs', 10, 0
msg_unknown db 'Unknown', 0
msg_kib     db ' KiB / ', 0
msg_mib     db ' MiB', 0
msg_alloc   db 'Sayfa ayrildi: #', 0
msg_heapis  db ' | heap: ', 0
msg_freed   db 'Sayfa birakildi.', 10, 0
msg_usage_free  db 'Kullanim: free sayfa_no', 10, 0
msg_usage_write db 'Kullanim: write dosya metin', 10, 0
msg_usage_file  db 'Dosya adi gerekli.', 10, 0
msg_written db 'Yazildi.', 10, 0
msg_removed db 'Silindi.', 10, 0
msg_bayt    db ' bayt', 10, 0
msg_dosya   db ' oge', 10, 0
msg_klasor  db '<klasor>', 10, 0
msg_created db 'Klasor olusturuldu.', 10, 0
msg_baddot  db 'Ad . ile baslayamaz.', 10, 0
msg_usage_mkdir db 'Kullanim: mkdir ad', 10, 0
msg_error   db 'Error ', 0
msg_colon   db ': ', 0
msg_dash    db ' - ', 0
msg_lasterr db 'Son hata kodu: ', 0
e0 db 'Hata yok', 10, 0
e1 db 'Bilinmeyen komut', 10, 0
e2 db 'Eksik veya hatali arguman', 10, 0
e3 db 'Dosya bulunamadi', 10, 0
e4 db 'Bellek yok (heap dolu)', 10, 0
e5 db 'Dizin dolu (128 dosya)', 10, 0
e6 db 'Gecersiz sayfa (sadece alloc ile ayrilanlar)', 10, 0
e7 db 'Gecersiz ifade', 10, 0
e8 db 'Sifira bolunemez', 10, 0
e9 db 'Klasor bos degil', 10, 0
e10 db 'Bu bir klasor', 10, 0
e11 db 'Klasor degil', 10, 0
e12 db 'Zaten var', 10, 0
e13 db 'Sonuc cok buyuk (1e18 ve uzeri)', 10, 0
e14 db 'Disk yazma hatasi (disk salt okunur olabilir)', 10, 0
e15 db 'Arka plan ve yazi rengi ayni olamaz', 10, 0
err_table dw e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13, e14, e15
last_err    db 0
msg_heapinfo db 'Heap sayfalari: ', 0
msg_sayfa   db ' sayfa = ', 0

hv_buf      times 12 db 0
            db 0
cpu_buf     times 48 db 0
            db 0
boot_ticks  dd 0
ui_exit     db 0
mbtn_r      db 0
press_state db 0
press_tick  dd 0
press_x     dw 0
press_y     dw 0
rel_pending db 0
ctx_pending db 0
ctx_row     dw 0
ctx_col     dw 0
menu_open   db 0
menu_target db 0
menu_row    dw 0
menu_col    dw 0
mv_mode     db 0
mv_idx      db 0
mv_lastx    dw 0
mv_lasty    dw 0
ic_n        db 0
ic_type     times 12 db 0
ic_col      times 12 db 0
ic_row      times 12 db 0
ico_t       db 0
ico_copy    db 0
ic_id       times 12 db 0
ic_par      times 12 db 0
tr_n        db 0
tr_type     times 12 db 0
ptool       db 0
pstat       dw 0
pl_size     db 1
bb_seg      dw 0
drag_pending db 0
mv_offx     db 3
mv_offy     db 1
tr_kind     times 12 db 0
tr_id       times 12 db 0
tr_col      times 12 db 0
tr_row      times 12 db 0
a_type      db 0
a_col       db 0
a_row       db 0
a_id        db 0
a_par       db 0
op_n        dw 0
op_dir      dw 0
op_ent      times 9 dw 0
tmp_lbl     times 40 db 0
fot_name    times 24 db 0
ico_r       db 0
ico_c       db 0
win_title   dw msg_win_title
pcolor      db 0
pc_seg      dw 0
pl_down     db 0
pl_x0       dw 0
pl_y0       dw 0
pl_x1       dw 0
pl_y1       dw 0
pl_dx       dw 0
pl_dy       dw 0
pl_st       dw 0
pl_col      db 0
pa_r        db 0
pa_x        db 0
u_state     db 0
u_name      times 16 db 0
u_hash      dd 0
in_name     times 16 db 0
in_pass     times 16 db 0
in_nlen     db 0
in_plen     db 0
foc         db 0
fld_mask    db 0
fld_foc     db 0
fld_attr    db 0
ctx_attr    db 0
clk_row     dw 0
clk_col     dw 0
clk_pending db 0
ui_active   db 0
win_open    db 0
ui_close_req db 0
cur_freeze  db 0
vp_x0       dw 0
vp_y0       dw 0
vp_x1       dw 79
vp_y1       dw 24
ui_click    db 0
mouse_ok    db 0
mbtn        db 0
pk_i        db 0
pk_buf      times 3 db 0
mpx         dw 320
mpy         dw 192
cur_valid   db 0
cur_off     dw 0
cur_saved   dw 0
clk_last    dw 0
adam_art:
; ART-BASLA
db 10, 10, 10
db '          MUSTAFA KEMAL ATATURK', 10
db '               1881 - 1938', 10, 10, 10
db '      "Yurtta sulh, cihanda sulh."', 10, 10
db "      Ne mutlu Turk'um diyene!", 10
; ART-BITIS
db 0
map_data:
    db '    .......            ..............', 10
    db '   .........+....  ......................            .........', 10
    db '    ...........................................................', 10
    db '    ......................................................#####', 10
    db '   ......................+................................#######.', 10
    db '     .....................................................#######', 10
    db '     ............................................................', 10
    db '    ..+.........................................................', 10
    db '       ..........................................................', 10
    db '        ..........................................................', 10
    db '        ............................................', 10
    db '              ....     .......       ...', 10
    db 0
bg_color    db 0
fg_color    db 7
bg_hi       db 0
scr_attr    db 7
old_bg      db 0
old_fg      db 7
new_bg      db 0
new_fg      db 0
sv_bg       db 0
sv_fg       db 0
xo_turn     db 1
xo_mode     db 1
xo_lvl      db 3
rng         dw 1
xo_p        db 0
xo_cnt      db 0
xo_emp      db 0
mm_move     db 0
xox_b       times 9 db 0
win_tbl     db 0,1,2, 3,4,5, 6,7,8, 0,3,6, 1,4,7, 2,5,8, 0,4,8, 2,4,6
calc_sp     dw 0
pn_dec      db 0
pn_n        dw 0
tmp16       dw 0
pf_neg      db 0
pf_frac     dd 0
fr_rest     dd 0
fr_div      dd 0
cw_trunc    dw 0x0F7F
cw_near     dw 0x037F
fp_10       dd 10.0
fp_1e6      dd 1000000.0
fp_big      dq 1.0e18
bcd_buf     times 10 db 0
pal_keys    db '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'
pal_syms    db '!@#$%^&*()_+{}|:"<>?~'
            db 0x07, 0xFB, 0xE3, 0xF6, 0x80, 0x15, 0x81, 0x9C
            db 0x82, 0x9B, 0xF8, 0x83, 0x84, 0x85, 0x86
pal_off     dw 0
pal_save    times 320 db 0

sym_table:
    db 'tick', 0, 0x60
    db 'bullet', 0, 0x07
    db 'sqrt', 0, 0xFB
    db 'pi', 0, 0xE3
    db 'div', 0, 0xF6
    db 'mul', 0, 0x80
    db 'sect', 0, 0x15
    db 'delta', 0, 0x81
    db 'pound', 0, 0x9C
    db 'euro', 0, 0x82
    db 'cent', 0, 0x9B
    db 'deg', 0, 0xF8
    db 'copy', 0, 0x83
    db 'reg', 0, 0x84
    db 'tm', 0, 0x85
    db 'check', 0, 0x86
    db 0

custom_font:
    db 0,0,0,0, 0x81,0x42,0x24,0x18,0x18,0x24,0x42,0x81, 0,0,0,0           ; 0x80 x
    db 0,0,0,0x10,0x28,0x28,0x44,0x44,0x82,0x82,0xFE,0,0,0,0,0             ; 0x81 delta
    db 0,0,0,0x3C,0x42,0x80,0xFC,0x80,0xFC,0x80,0x42,0x3C,0,0,0,0          ; 0x82 euro
    db 0,0,0,0x3C,0x42,0x99,0xA1,0xA1,0x99,0x42,0x3C,0,0,0,0,0             ; 0x83 (c)
    db 0,0,0,0x3C,0x42,0xB9,0xAD,0xB1,0xA9,0x42,0x3C,0,0,0,0,0             ; 0x84 (r)
    db 0,0,0,0xE9,0x4F,0x49,0x49,0,0,0,0,0,0,0,0,0                         ; 0x85 tm
    db 0,0,0,0,0x03,0x06,0x8C,0xD8,0x70,0x20,0,0,0,0,0,0                   ; 0x86 check
    db 0x80,0xC0,0xE0,0xF0,0xF8,0xFC,0xFE,0xFF,0xFC,0xD8,0x98,0x0C,0x0C,0x06,0x06,0x00   ; 0x87 fare oku
    db 0,0,0,0,0,0,0x38,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0,0                   ; 0x88 noktasiz i
    db 0,0,0,0,0,0,0x7C,0xC6,0x60,0x38,0x0C,0xC6,0x7C,0x18,0x0C,0x78             ; 0x89 s (kuyruklu)
    db 0,0,0x7C,0xC6,0xC6,0x60,0x38,0x0C,0x06,0xC6,0xC6,0x7C,0x18,0x0C,0x78,0    ; 0x8A S (kuyruklu)
    db 0,0,0x3C,0x66,0xC2,0xC0,0xC0,0xC0,0xC2,0x66,0x3C,0x18,0x0C,0x78,0,0       ; 0x8B C (kuyruklu)
    db 0,0x18,0x18,0,0x3C,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x3C,0,0,0           ; 0x8C noktali I
    db 0,0,0,0,0,0,0x3C,0x66,0x60,0x60,0x66,0x3C,0x18,0x0C,0x78,0                  ; 0x8D c (kuyruklu)
argptr      dw 0
restptr     dw 0
tmpoff      dw 0
fs_dir_seg  dw 0
pl_n        dw 0
pl_i        dw 0
rw_lba      dw 0
rw_fn       db 0
rw_buf      dw 0
rel_n       dw 0
pl_typ      times 252 db 0
pl_seg      times 252 dw 0
tmpseg      dw 0
cur_dir_seg dw 0
cwd_path    db '/'
            times 63 db 0
lscount     dd 0
namebuf     times 28 db 0
umap        times 160 db 0

cursor      dw 0
attr        db 0x07
used_pages  dd 0
reserved_kb dd 0
pg_low      dd 0
pg_map      dd 0
pg_kernel   dd 0
pg_heap     dd 0
numbuf      times 11 db 0
numend      db 0

times 512 + S2_SECT * 512 - ($ - $$) db 0     ; stage2 = S2_SECT sektor
