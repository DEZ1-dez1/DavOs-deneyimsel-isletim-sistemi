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

Stage 1 ve Stage 2 aşamalarından oluşan özel önyükleme mimarisi; bellek yönetimi, RAM tabanlı dosya sistemi, x87 FPU destekli hesap makinesi ve etkileşimli komut satırı gibi özelliklerle bir araya gelir.

DavOS'un temel amacı, işletim sistemlerinin çalışma mantığını düşük seviyede incelemek ve temel sistem mekanizmalarını doğrudan Assembly ile uygulamaktır.

✨ Öne Çıkan Özellikler

<table>
<tr>
<td width="50%">
<h3>⚡ Özel Önyükleyici</h3>
512 baytlık Stage 1 boot sektöründen başlayarak diskten 9 KB (18 sektör) Stage 2 bileşeninin yüklenmesi.
</td>
<td width="50%">
<h3>🧠 Bellek Yönetimi</h3>
BIOS E820 ile bellek haritasının tespiti ve bitmap tabanlı 4 KB bellek sayfalarının ayrılması ve serbest bırakılması.
</td>
</tr>
<tr>
<td width="50%">
<h3>📁 RAM Dosya Sistemi</h3>
Hiyerarşik klasör yapısı, dosya işlemleri ve heap tabanlı bellek kullanımı.
</td>
<td width="50%">
<h3>🔢 x87 FPU Hesap Makinesi</h3>
Ondalıklı sayılar, parantezler ve temel aritmetik işlemlerle matematiksel hesaplamalar.
</td>
</tr>
<tr>
<td width="50%">
<h3>🎨 Özel Sembol Paleti</h3>
Backtick ( ` ) tuşu veya `SYM` komutuyla π, √, Δ ve € gibi özel karakterlere erişim.
</td>
<td width="50%">
<h3>🖥️ Neofetch Benzeri Arayüz</h3>
Renkli logo, CPU bilgileri, çalışma süresi ve sistem detaylarını gösteren komut satırı aracı.
</td>
</tr>
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

💻 Komut Listesi

DavOS terminalinde local_user$ istemi üzerinden kullanılabilen temel komutlar:

Komut	Açıklama
help	Kullanılabilir komutları listeler.
neofetch	Sistem logosunu ve sistem bilgilerini gösterir.
ram	Boş, kullanılan ve ayrılmış bellek miktarlarını gösterir.
hesap	x87 FPU tabanlı hesap makinesini başlatır.
ls	Dosya ve klasörleri listeler.
mkdir	Yeni bir klasör oluşturur.
cd	Geçerli klasörü değiştirir.
pwd	Geçerli klasörün yolunu gösterir.
write	Dosyaya yazma işlemini gerçekleştirir.
cat	Dosya içeriğini görüntüler.
rm	Dosya siler.
alloc	Bellek sayfası ayırır.
free	Ayrılmış belleği serbest bırakır.
heap	Heap bellek yönetimi bilgilerini gösterir.
ver	İşletim sistemi sürümünü gösterir.
reboot	Sistemi yeniden başlatır.
halt	Sistemi durdurur.
💡 Komutların kullanım biçimlerini öğrenmek için DavOS içerisinde help komutunu çalıştırabilirsin.
🖥️ Sistem Bilgileri
text
       ____  
      |  _ \  
      | | | |
      | |_| | 
      |____/ 

      DavOS - Mini İşletim Sistemi
      --------------------------------
      Mimari       : x86
      Önyükleme    : Stage 1 + Stage 2
      Bellek       : Bitmap tabanlı sayfalama
      Dosya Sistemi: RAM tabanlı
      Hesap Makinesi: x87 FPU

🗺️ Geliştirme Yol Haritası
Özel Stage 1 ve Stage 2 önyükleme mimarisi
BIOS E820 bellek haritası tespiti
Bitmap tabanlı bellek sayfası yönetimi
RAM tabanlı dosya sistemi
Hiyerarşik klasör yapısı
x87 FPU destekli hesap makinesi
Etkileşimli komut satırı araçları
Dosya sistemi özelliklerinin genişletilmesi
Yeni sistem araçlarının eklenmesi
Hata ayıklama araçlarının geliştirilmesi
Not: Yol haritasındaki tamamlanmış ve planlanan maddeleri projenin gerçek durumuna göre güncelleyebilirsin.
📜 Lisans

DavOS, MIT Lisansı altında yayımlanmaktadır.

Ayrıntılar için depodaki LICENSE dosyasına göz atabilirsin.

<div align="center">

 -DavOS


</div>
