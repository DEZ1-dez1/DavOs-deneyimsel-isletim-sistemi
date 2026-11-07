🚀 DavOS — Sıfırdan Geliştirilen Mini İşletim Sistemi

<div align="center">



<p>
<strong>Assembly ile sıfırdan geliştirilmiş, x86 tabanlı mini işletim sistemi.</strong>
<br />
Özel önyükleyici · Bellek yönetimi · RAM dosya sistemi · Komut satırı
</p>

<img src="https://img.shields.io/badge/Mimari-x86-blue?style=for-the-badge&logo=intel&logoColor=white" alt="x86 mimarisi" />
<img src="https://img.shields.io/badge/Dil-Assembly-6E4C13?style=for-the-badge" alt="Assembly" />
<img src="https://img.shields.io/badge/Derleyici-NASM-orange?style=for-the-badge" alt="NASM" />
<img src="https://img.shields.io/badge/Lisans-MIT-green?style=for-the-badge" alt="MIT lisansı" />

<br />

İlk önyükleme sektöründen etkileşimli komut satırına kadar her şey düşük seviyede.

</div>

📖 DavOS Nedir?

DavOS, x86 mimarisi için Assembly dili kullanılarak sıfırdan geliştirilmiş bir mini işletim sistemidir.

Stage 1 ve Stage 2 aşamalarından oluşan özel önyükleme mimarisi.

DavOS'un temel amacı, işletim sistemlerinin çalışma mantığını düşük seviyede incelemek ve temel sistem mekanizmalarını doğrudan Assembly ile uygulamaktır.

✨ Öne Çıkan Özellikler

<table>
<tr>
<td width="50%">
       --------------
       tekrar yazılıcak
       --------------
</td>
</table>

🛠️ Kullanılan Teknolojiler

<div align="center">

<img src="https://img.shields.io/badge/Assembly-Düşük_Seviye_Programlama-6E4C13?style=flat-square" alt="Assembly dili" />
<img src="https://img.shields.io/badge/NASM-Assembler-orange?style=flat-square" alt="NASM assembler" />
<img src="https://img.shields.io/badge/x86-İşlemci_Mimarisi-blue?style=flat-square" alt="x86 mimarisi" />
<img src="https://img.shields.io/badge/BIOS-E820_Bellek_Haritası-purple?style=flat-square" alt="BIOS E820" />
<img src="https://img.shields.io/badge/QEMU-Emülasyon-red?style=flat-square" alt="QEMU" />

</div>

⚙️ Derleme ve Kurulum
Gereksinimler
NASM — Assembly kaynak kodunu derlemek için.
coreutils — Disk imajını boyutlandırmak için.
QEMU veya Limbo PC Emulator — İşletim sistemini çalıştırmak için.
1. Kaynak kodunu derle

Proje dizininde aşağıdaki komutu çalıştır:

bash
nasm -f bin davos_v090.asm -o davos.img

2. Disk imajını boyutlandır

İmajı standart 1,44 MB disket boyutuna getir:

bash
truncate -s 1440k davos.img

3. DavOS'u çalıştır

QEMU üzerinden başlatmak için:

bash
qemu-system-i386 -fda davos.img


Limbo PC Emulator kullanıyorsan davos.img dosyasını Floppy (FDA) olarak seçip sanal makineyi başlatabilirsin.

--------------
yeniden yazılcak
--------------

Not: Yol haritasındaki tamamlanmış ve planlanan maddeleri projenin gerçek durumuna göre güncelleyebilirsin.
📜 Lisans

DavOS, MIT Lisansı altında yayımlanmaktadır.

Ayrıntılar için depodaki LICENSE dosyasına göz atabilirsin.

<div align="center">

 -DavOS


</div>
