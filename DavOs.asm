: boot bilgileri -> 3 sn bekle -> ekran temizle -> local_user$ CLI

[bits 16]
[org 0x7C00]

VER_MAJOR    equ 0
VER_MINOR    equ 9
VER_PATCH    equ 0
BITMAP_SEG   equ 0x2000          ; fiziksel 0x20000
BITMAP_BYTES equ 16384
MAXPAGES     equ 131072          ; 512 MB / 4 KB
E820BUF      equ 0x9A00
CMDBUF       equ 0x9B00          ; komut satiri tamponu (64 bayt)
HEAP_FIRST   equ 10              ; heap: 0xA000'dan
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
ERR_MAX      equ 13

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

    mov si, 3
.retry:
    xor ax, ax                   ; disk reset
    mov dl, [bootdrv]
    int 0x13
    mov ax, 0x0212               ; oku, 18 sektor (9 KB)
    mov bx, 0x7E00
    mov cx, 0x0002               ; silindir 0, sektor 2
    xor dh, dh
    mov dl, [bootdrv]
    int 0x13
    jnc stage2_start
    dec si
    jnz .retry

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
    mov cx, 7
    mov dx, 0x80
    mov bp, custom_font
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
    mov esi, 10
    call lock_range
    mov eax, [used_pages]
    mov [pg_low], eax
    mov edx, 0x20
    mov esi, 4
    call lock_range
    mov eax, [used_pages]
    sub eax, [pg_low]
    mov [pg_map], eax

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
    call clear_screen

; =====================================================
; CLI
; =====================================================
shell:
    mov byte [attr], 0x0A
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
    jmp shell

; ---- Satir oku (CMDBUF'a, 0 ile biter)
read_line:
    push ax
    push bx
    push cx
    xor cx, cx
.k: call set_hwcursor
    xor ah, ah
    int 0x16
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
    jc .k                        ; iptal
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
    mov bx, [cursor]
    sub bx, 2
    mov [cursor], bx
    mov word [gs:bx], 0x0720
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

; Paleti ac, bir tusa basilmasini bekle. AL = secilen sembol, CF=1 iptal
palette_pick:
    call show_palette
    xor ah, ah
    int 0x16
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
    clc
    ret
.cancel:
    call hide_palette
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

logo:                            ; BP'deki logo satirini cyan yazdir
    push si
    mov byte [attr], 0x0B
    mov si, bp
    call print
    mov bp, si
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
    ret
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
    ret
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
    ret
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
    ret
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
clear_screen:
    push es
    push ax
    push cx
    push di
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov cx, 2000
    mov ax, 0x0720
    cld
    rep stosw
    mov word [cursor], 0
    pop di
    pop cx
    pop ax
    pop es
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

putc:                            ; AL = karakter, [attr] rengi
    push ax
    push bx
    push cx
    push dx
    push di
    mov di, [cursor]
    cmp al, 10
    je .nl
    mov ah, [attr]
    mov [gs:di], ax
    add di, 2
    jmp .chk
.nl:
    mov ax, di
    xor dx, dx
    mov cx, 160
    div cx
    inc ax
    mul cx
    mov di, ax
.chk:
    cmp di, 4000
    jb .s
    call scroll
    mov di, 3840
.s: mov [cursor], di
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

scroll:                          ; ekrani 1 satir yukari kaydir
    push ds
    push es
    push si
    push di
    push cx
    push ax
    mov ax, 0xB800
    mov ds, ax
    mov es, ax
    mov si, 160
    xor di, di
    mov cx, 1920
    cld
    rep movsw
    mov ax, 0x0720
    mov cx, 80
    mov di, 3840
    rep stosw
    pop ax
    pop cx
    pop di
    pop si
    pop es
    pop ds
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
msg_calc_info db 'Hesap: + - * x / % ( ) [ ] ! kesir . ,   Bos satir = cikis', 10, 0
msg_ver_tail db ' (x86 16-bit real mode)', 10, 0
msg_halt   db 'Sistem durduruldu.', 10, 0
msg_unk2   db ' bilinmiyor. Komutlar icin help yaz.', 10, 0

s_help     db 'help', 0
s_q        db '?', 0
s_sym      db 'sym', 0
s_hesap    db 'hesap', 0
s_mkdir    db 'mkdir', 0
s_cd       db 'cd', 0
s_pwd      db 'pwd', 0
s_calc     db 'calc', 0
s_clear    db 'clear', 0
s_ram      db 'ram', 0
s_ver      db 'ver', 0
s_reboot   db 'reboot', 0
s_halt     db 'halt', 0
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
    dw s_mkdir,  cmd_mkdir
    dw s_cd,     cmd_cd
    dw s_pwd,    cmd_pwd
    dw s_calc,   cmd_calc
    dw s_clear,  cmd_clear
    dw s_ram,    cmd_ram
    dw s_ver,    cmd_ver
    dw s_reboot, cmd_reboot
    dw s_halt,   cmd_halt
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
    db '  help     ', 0, '- Komutlari ve aciklamalarini listeler', 10, 0
    db '  clear    ', 0, '- Ekrani temizler', 10, 0
    db '  ram      ', 0, '- Free/Used/Reserved bellek durumu', 10, 0
    db '  ver      ', 0, '- DavOS surum bilgisi', 10, 0
    db '  neofetch ', 0, '- Logo ile sistem bilgisi', 10, 0
    db '  echo     ', 0, '- echo metin: metni ekrana basar', 10, 0
    db '  ls       ', 0, '- Dosyalari listeler', 10, 0
    db '  write    ', 0, '- write dosya metin: dosya olustur/yaz', 10, 0
    db '  cat      ', 0, '- cat dosya: dosyayi gosterir', 10, 0
    db '  rm       ', 0, '- rm ad: dosya veya bos klasoru siler', 10, 0
    db '  mkdir    ', 0, '- mkdir ad: klasor olusturur', 10, 0
    db '  cd       ', 0, '- cd ad | cd .. | cd /: klasor degistirir', 10, 0
    db '  pwd      ', 0, '- Bulundugun klasoru gosterir', 10, 0
    db '  alloc    ', 0, '- Heap uzerinden 1 sayfa (4 KB) ayirir', 10, 0
    db '  free     ', 0, '- free N: alloc sayfasini birakir', 10, 0
    db '  heap     ', 0, '- Heap kullanimini gosterir', 10, 0
    db '  err      ', 0, '- Son hata kodunu gosterir', 10, 0
    db '  errors   ', 0, '- Tum hata kodlarini listeler', 10, 0
    db '  hesap    ', 0, '- Hesap: + - * / % ( ) ! kesir (bos = cikis)', 10, 0
    db '  sym      ', 0, '- :isim: veya ;isim; ile semboller', 10, 0
    db '  `        ', 0, '- Sembol paleti: 1-9,0,A-Z ile sec', 10, 0
    db '  reboot   ', 0, '- Yeniden baslatir', 10, 0
    db '  halt     ', 0, '- Islemciyi durdurur', 10, 0
    db 0

; ---- neofetch verisi
%macro LG 1
%%a: db %1
    times 26 - ($ - %%a) db ' '
    db 0
%endmacro

logo_table:
    LG '   ############'
    LG '   ##############'
    LG '   ####        ####'
    LG '   ####          ####'
    LG '   ####           ####'
    LG '   ####           ####'
    LG '   ####           ####'
    LG '   ####           ####'
    LG '   ####          ####'
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
err_table dw e0, e1, e2, e3, e4, e5, e6, e7, e8, e9, e10, e11, e12, e13
last_err    db 0
msg_heapinfo db 'Heap sayfalari: ', 0
msg_sayfa   db ' sayfa = ', 0

hv_buf      times 12 db 0
            db 0
cpu_buf     times 48 db 0
            db 0
boot_ticks  dd 0
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
argptr      dw 0
restptr     dw 0
tmpoff      dw 0
tmpseg      dw 0
fs_dir_seg  dw 0
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

times 512 + 9216 - ($ - $$) db 0   
