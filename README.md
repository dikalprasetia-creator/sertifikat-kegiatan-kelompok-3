# Aplikasi Sertifikat Kegiatan Berbasis Blockchain

**Kelompok 3 - Pemrograman Mobile 2**

## Deskripsi

Aplikasi Sertifikat Kegiatan Berbasis Blockchain merupakan aplikasi mobile berbasis Flutter yang digunakan untuk mengelola dan memverifikasi keaslian sertifikat kegiatan menggunakan teknologi Blockchain Ethereum Sepolia.

Aplikasi menyediakan fitur admin untuk mendaftarkan sertifikat dan fitur mahasiswa untuk melihat serta memverifikasi sertifikat berdasarkan Nomor Induk Mahasiswa (NIM).

## Fitur Aplikasi

### 1. Admin
- Login sebagai admin.
- Menghubungkan aplikasi dengan MetaMask menggunakan Reown AppKit.
- Memasukkan nama penerbit dan nama kegiatan.
- Mengunggah sertifikat dalam format PDF, JPG, atau PNG.
- Menghasilkan hash sertifikat menggunakan SHA-256.
- Mendaftarkan sertifikat ke blockchain.
- Memperbarui data sertifikat blockchain.

### 2. Mahasiswa
- Login menggunakan NIM.
- Melihat dashboard mahasiswa.
- Melihat sertifikat yang terhubung dengan NIM.
- Melakukan verifikasi keaslian sertifikat.
- Memeriksa data sertifikat berdasarkan hash pada blockchain.

## Teknologi yang Digunakan

| Teknologi | Fungsi |
|---|---|
| Flutter | Framework aplikasi mobile |
| Dart | Bahasa pemrograman |
| Solidity | Smart Contract |
| Ethereum Sepolia | Jaringan blockchain |
| MetaMask | Wallet blockchain |
| Reown AppKit | Koneksi wallet |
| SQLite | Penyimpanan data lokal |
| SHA-256 | Algoritma hash sertifikat |
| GitHub | Penyimpanan repository kode |

## Dependencies

- reown_appkit: ^1.9.0
- file_picker: 11.0.3
- crypto: ^3.0.8
- http: ^1.6.0
- url_launcher: ^6.3.3
- sqflite: ^2.4.2
- path: ^1.9.1

## Cara Menjalankan Aplikasi

### Persyaratan
- Flutter SDK
- Android Studio
- Visual Studio Code
- Android SDK
- MetaMask

### Instalasi

Clone repository:

```bash
git clone https://github.com/dikalprasetia-creator/sertifikat-kegiatan-kelompok-3.git
```

Masuk ke folder proyek:

```bash
cd sertifikat-kegiatan-kelompok-3
```

Instal dependencies:

```bash
flutter pub get
```

Jalankan aplikasi:

```bash
flutter run
```

### Build APK

```bash
flutter build apk --release
```

Lokasi hasil build:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Konfigurasi Blockchain

| Konfigurasi | Nilai |
|---|---|
| Network | Ethereum Sepolia Testnet |
| Chain ID | 11155111 |
| Chain ID Hex | 0xaa36a7 |
| Explorer | Etherscan Sepolia |

### Smart Contract Address

```text
0x519050FC1a2eAD8355F590BC06813a228210aa90
```

### Etherscan

https://sepolia.etherscan.io/address/0x519050FC1a2eAD8355F590BC06813a228210aa90

## Fungsi Smart Contract

Smart Contract memiliki fungsi utama:

- `addCertificate`: Mendaftarkan sertifikat ke blockchain.
- `verifyCertificate`: Memverifikasi sertifikat berdasarkan hash.
- `certificates`: Mengambil informasi sertifikat.
- `owner`: Melihat alamat pemilik kontrak.

## Database SQLite

SQLite digunakan untuk menyimpan dan menghubungkan data sertifikat dengan NIM mahasiswa pada perangkat yang digunakan bersama oleh admin dan mahasiswa.

Blockchain digunakan untuk pencatatan dan verifikasi keaslian sertifikat melalui hash SHA-256.

## Struktur Proyek

```text
sertifikat-kegiatan-kelompok-3/
├── android/
├── assets/
│   └── CertificateRegistrySecure.json
├── ios/
├── lib/
│   └── main.dart
├── linux/
├── macos/
├── test/
├── web/
├── windows/
├── pubspec.yaml
├── pubspec.lock
└── README.md
```

## Repository GitHub

https://github.com/dikalprasetia-creator/sertifikat-kegiatan-kelompok-3

---

**Kelompok 3 - Pemrograman Mobile 2**

Aplikasi Sertifikat Kegiatan Berbasis Blockchain menggunakan Flutter dan Ethereum Sepolia Testnet.