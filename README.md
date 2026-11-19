# APLIKASI SERTIFIKAT KEGIATAN BERBASIS BLOCKCHAIN

**Kelompok 3 – Pemrograman Mobile 2**

## 1. Deskripsi Aplikasi

Aplikasi Sertifikat Kegiatan Berbasis Blockchain merupakan aplikasi mobile berbasis Flutter yang digunakan untuk mengelola, menyimpan, dan memverifikasi keaslian sertifikat kegiatan menggunakan teknologi Blockchain Ethereum Sepolia Testnet.

Aplikasi ini memiliki dua jenis pengguna, yaitu Admin dan Mahasiswa. Admin bertugas mendaftarkan sertifikat kegiatan ke blockchain, sedangkan mahasiswa dapat melihat dan memverifikasi sertifikat berdasarkan Nomor Induk Mahasiswa (NIM).

Aplikasi menggunakan SQLite sebagai database lokal untuk menghubungkan data sertifikat dengan NIM mahasiswa pada satu perangkat.

## 2. Fitur Aplikasi

### A. Admin
- Login sebagai admin.
- Menghubungkan aplikasi dengan MetaMask menggunakan Reown AppKit.
- Memilih file sertifikat dalam format PDF, JPG, atau PNG.
- Menghitung nilai hash SHA-256 sertifikat.
- Mendaftarkan sertifikat ke Smart Contract Ethereum Sepolia.
- Melihat hash sertifikat.
- Menyalin hash sertifikat.
- Memperbarui data blockchain.

### B. Mahasiswa
- Login menggunakan NIM.
- Melihat sertifikat yang terhubung dengan NIM.
- Melihat daftar sertifikat yang telah didaftarkan admin.
- Memverifikasi keaslian sertifikat berdasarkan hash SHA-256.
- Memeriksa data sertifikat yang tercatat pada blockchain.

## 3. Teknologi yang Digunakan

| Teknologi | Kegunaan |
|---|---|
| Flutter | Pengembangan aplikasi mobile |
| Dart | Bahasa pemrograman |
| SQLite | Penyimpanan data lokal |
| Solidity | Smart Contract |
| Ethereum Sepolia | Jaringan blockchain |
| MetaMask | Dompet kripto |
| Reown AppKit | Koneksi wallet |
| SHA-256 | Menghitung hash sertifikat |
| Etherscan | Memeriksa transaksi blockchain |

## 4. Dependencies

Beberapa package utama yang digunakan:

- `reown_appkit`
- `file_picker`
- `crypto`
- `http`
- `url_launcher`
- `sqflite`
- `path`

Versi package dapat dilihat pada file `pubspec.yaml`.

## 5. Konfigurasi Blockchain

Aplikasi menggunakan jaringan Ethereum Sepolia Testnet.

| Konfigurasi | Nilai |
|---|---|
| Network | Sepolia |
| Chain ID | 11155111 |
| Symbol | SepoliaETH |
| RPC | https://sepolia.infura.io/v3/ |
| Block Explorer | https://sepolia.etherscan.io/ |

### Alamat Smart Contract

`0xEF9187598b2D6165F07fBa345bfEa70dBdBBD4dc`

### Link Smart Contract Etherscan

https://sepolia.etherscan.io/address/0xEF9187598b2D6165F07fBa345bfEa70dBdBBD4dc

## 6. Bukti Transaksi Blockchain

Aplikasi telah berhasil melakukan pemanggilan fungsi `addCertificate` pada Smart Contract Ethereum Sepolia.

**Informasi transaksi:**

- Fungsi: `addCertificate`
- Status: Success
- Jumlah konfirmasi: 106 (saat pemeriksaan)
- Transaction Hash:

`0x3d769a02325c2004497abe533356c3ccef5a80b33f9711888557088cf8792781`

### Link Pemeriksaan Transaksi

https://sepolia.etherscan.io/tx/0x3d769a02325c2004497abe533356c3ccef5a80b33f9711888557088cf8792781

## 7. Struktur Proyek

```text
sertifikat_kegiatan_final/
│
├── android/
├── assets/
│   └── CertificateRegistrySecure.json
│
├── lib/
│   └── main.dart
│
├── test/
├── web/
├── windows/
│
├── pubspec.yaml
├── pubspec.lock
└── README.md
```

## 8. Cara Menjalankan Aplikasi

### Persyaratan
- Flutter SDK
- Dart SDK
- Android Studio atau VS Code
- Android Emulator atau perangkat Android
- MetaMask
- Koneksi internet

### Langkah menjalankan

1. Clone repository:

```bash
git clone https://github.com/dikalprasetia-creator/sertifikat-kegiatan-kelompok-3.git
```

2. Masuk ke folder proyek:

```bash
cd sertifikat-kegiatan-kelompok-3
```

3. Instal dependencies:

```bash
flutter pub get
```

4. Jalankan aplikasi:

```bash
flutter run
```

## 9. Cara Build APK

Untuk membuat APK release, jalankan:

```bash
flutter build apk --release
```

File APK berada di:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## 10. Repository

GitHub Repository:

https://github.com/dikalprasetia-creator/sertifikat-kegiatan-kelompok-3

## 11. Pengembang

**Kelompok 3 – Pemrograman Mobile 2**

Proyek: Aplikasi Sertifikat Kegiatan Berbasis Blockchain.

Teknologi utama: Flutter dan Ethereum Sepolia Testnet.