# Test Integritas QRIS - Yokke (SNAP MPM)

![Bash](https://img.shields.io/badge/Bash-Installer-4EAA25?logo=gnu-bash&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-%3E%3D14-339933?logo=node.js&logoColor=white)
![Express](https://img.shields.io/badge/Express-Backend-000000?logo=express&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Linux%20VPS-informational)
![Status](https://img.shields.io/badge/Status-Sandbox%2FTesting-orange)

Toolkit pengujian integrasi API **QRIS SNAP MPM** (Merchant Presented Mode) untuk sandbox **Yokke**, sesuai Postman Collection *"Sandbox QRIS MPM"*. Mendukung 4 endpoint utama: **Access Token**, **QR Generate**, **QR Query**, dan **QR Cancel**.

Toolkit ini menyediakan **dua cara pakai** yang saling terhubung:

1. **CLI interaktif** (`qris-test.sh`) — dijalankan langsung dari terminal.
2. **Web Panel** (Node.js/Express) — dashboard berbasis browser, bisa diakses lewat `http://<IP-VPS>:<PORT>`.

Konfigurasi (client key, partner ID, merchant ID, signature, dll.) bisa diisi lewat CLI **atau** Web Panel — keduanya otomatis saling menyinkronkan (`config.env` ↔ `config.json`).

---

## ✨ Fitur

- **Access Token** — generate token dengan signature asimetris (RSA-SHA256).
- **QR MPM Generate** — buat QR pembayaran dengan signature simetris (HMAC-SHA512).
- **QR MPM Query** — cek status transaksi.
- **QR MPM Cancel** — batalkan transaksi.
- **Full Flow** — jalankan seluruh alur (token → generate → query) sekali klik/perintah.
- **Payment Notify Webhook** (`/qr/qr-mpm-notify`) — endpoint penerima callback notifikasi pembayaran dari Yokke/BMRI, otomatis membalas `responseCode 2005300`.
- **Generate RSA Key Pair** langsung dari CLI maupun Web Panel.
- **Logging lengkap** tiap request/response (header, body, HTTP code) — bisa dilihat dan dibersihkan dari CLI/Web.
- **Export Test Case ke Excel** (`.xlsx`) sesuai format referensi *SIT-QR_MPM_SNAP-_API_Test_Review*, lengkap dengan styling status Pass/Fail.
- **Login & manajemen sesi** untuk Web Panel (ganti password, dsb).
- **Mode signature**: manual (paste sendiri) atau auto (generate via OpenSSL).
- **Kelola domain & SSL** langsung dari menu CLI.
- Auto-install dependency (`curl`, `jq`, `openssl`, `node`, `npm`) saat instalasi.
- Web Panel otomatis berjalan sebagai **service systemd** (jika root & systemd aktif), atau fallback ke background process (`nohup`).

---

## 🧱 Tech Stack

- **Bash** — installer & CLI (`qris-test.sh`)
- **Node.js / Express** — backend Web Panel
- **ExcelJS** — export test case ke Excel
- **OpenSSL** — signature RSA-SHA256 & HMAC-SHA512
- **systemd** (opsional) — menjalankan Web Panel sebagai service

---

## 🖼️ Screenshot

> Ganti gambar di bawah dengan screenshot asli Web Panel kamu. Simpan file di folder `screenshots/` pada repo, lalu sesuaikan path-nya.

| Login | Dashboard | Log & Test Case |
|---|---|---|
| ![Login](screenshots/login.png) | ![Dashboard](screenshots/dashboard.png) | ![Logs](screenshots/logs.png) |

<sub>Contoh: `screenshots/login.png`, `screenshots/dashboard.png`, `screenshots/logs.png` — upload gambar ke folder tersebut agar tampil otomatis di GitHub.</sub>

---

## 📦 Instalasi

```bash
git clone https://github.com/tendostore/Test-Integritas-Qris-Yokke.git
cd Test-Integritas-Qris-Yokke
chmod +x install.sh
./install.sh
```

Installer akan:
1. Mengecek & memasang dependency yang belum ada.
2. Membuat direktori instalasi di `~/qris-snap-test` (bisa diubah lewat env `QRIS_TEST_DIR`).
3. Menulis konfigurasi awal (`config.env`, `config.json`).
4. Memasang CLI (`qris-test.sh`) dan Web Panel (`web/server.js`).
5. Menjalankan Web Panel (systemd jika memungkinkan, atau background process).

### Opsi environment saat instalasi

| Variabel | Default | Keterangan |
|---|---|---|
| `QRIS_TEST_DIR` | `$HOME/qris-snap-test` | Lokasi instalasi |
| `QRIS_PORT` | `3000` | Port Web Panel |

Contoh custom port:
```bash
QRIS_PORT=7080 ./install.sh
```

---

## 🚀 Cara Pakai

### CLI
```bash
cd ~/qris-snap-test
./qris-test.sh
```
Menu CLI mencakup: Access Token, QR Generate, QR Query, QR Cancel, Full Flow, Lihat/Bersihkan Log, Kelola SSL & Domain, Generate RSA Key Pair, Edit Konfigurasi, Backup & Restore, Restart Layanan.

### Web Panel
Buka di browser:
```
http://<IP-VPS-ANDA>:<PORT>
```
Login menggunakan akun yang dibuat saat instalasi, lalu atur konfigurasi di tab **Konfigurasi** sebelum menjalankan pengujian.

> Perubahan konfigurasi dari CLI maupun Web Panel akan otomatis tersinkronisasi ke kedua sisi.

---

## ⚙️ Konfigurasi Penting

Isi minimal sebelum testing:
- `BASE_URL` (default: `https://tst.yokke.co.id:8280`)
- `CLIENT_KEY`
- Data merchant (merchant ID, partner ID, dst.)
- Mode signature: **manual** atau **auto**

Untuk menerima callback notifikasi pembayaran, daftarkan URL berikut ke pihak bank/Yokke:
```
https://<DOMAIN-ANDA>/qr/qr-mpm-notify
```

---

## 📁 Struktur Instalasi

```
~/qris-snap-test/
├── config.env        # Konfigurasi versi CLI
├── config.json        # Konfigurasi versi Web Panel (sinkron dengan config.env)
├── auth.json          # Data login Web Panel
├── qris-test.sh        # Tool CLI utama
├── keys/              # RSA key pair
├── logs/              # Log request/response
└── web/
    ├── server.js       # Backend Express
    └── public/
```

---

## ⚠️ Disclaimer

Toolkit ini dibuat untuk keperluan **pengujian/sandbox** integrasi QRIS SNAP MPM. Simpan kredensial (client key, private key, dsb.) dengan aman dan jangan gunakan konfigurasi sandbox untuk transaksi produksi.

## 📝 Lisensi

Proyek ini dirilis di bawah lisensi **MIT** — bebas digunakan, dimodifikasi, dan didistribusikan, dengan syarat mencantumkan atribusi ke pemilik asli. Lihat file [`LICENSE`](./LICENSE) untuk teks lengkap.
