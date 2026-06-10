# Tutorial: Mengaktifkan MCP Server Supabase

Tutorial ini untuk mengaktifkan MCP (Model Context Protocol) Server Supabase agar bisa mengakses database tanpa lewat terminal.

## Apa itu MCP Server Supabase?

MCP Server Supabase adalah server yang memungkinkan AI assistant (seperti Cascade) untuk:
- Melihat struktur database
- Menjalankan query SQL
- Mengelola migration
- Mengakses resources Supabase lainnya

## Langkah 1: Verifikasi Konfigurasi `.mcp.json`

File `.mcp.json` sudah dikonfigurasi dengan benar di project Anda:

```json
{
  "mcpServers": {
    "supabase": {
      "command": "npx",
      "args": [
        "-y",
        "@supabase/mcp-server"
      ]
    }
  }
}
```

**Catatan**: MCP Server Supabase menggunakan OAuth 2.1 untuk autentikasi, jadi tidak perlu `SUPABASE_URL` atau `SUPABASE_SERVICE_ROLE_KEY` di env variables.

## Langkah 2: Restart IDE

**PENTING**: Anda HARUS restart IDE (Windsurf/Cascade) agar konfigurasi `.mcp.json` yang baru bisa terbaca.

### Cara Restart IDE:
1. Tutup Windsurf/Cascade sepenuhnya
2. Buka Windsurf/Cascade lagi
3. Buka project ini

## Langkah 3: Autentikasi OAuth (Saat Pertama Kali)

Setelah restart, saat pertama kali menggunakan MCP server Supabase:

1. AI akan meminta Anda untuk melakukan autentikasi
2. Anda akan diarahkan ke browser untuk login ke Supabase
3. Setelah login, grant akses ke project Anda
4. Kembali ke IDE dan session akan terautentikasi

## Langkah 4: Verifikasi Koneksi

Setelah restart dan autentikasi, AI bisa menggunakan MCP tools untuk:
- `list_resources` - Melihat resources yang tersedia
- `read_resource` - Membaca resource spesifik
- Tools database lainnya

## Troubleshooting

### Masalah: MCP server tidak ditemukan
**Solusi**: Pastikan IDE sudah di-restart. Konfigurasi tidak akan terbaca tanpa restart.

### Masalah: Autentikasi gagal
**Solusi**: 
- Pastikan Anda sudah login ke Supabase di browser
- Coba autentikasi ulang
- Pastikan project ID benar

### Masalah: Server tidak merespons
**Solusi**: Cek apakah server Supabase MCP bisa diakses:
```bash
curl -i https://mcp.supabase.com/mcp
```
Harus return HTTP 401 (server up tapi butuh token).

## Keuntungan Menggunakan MCP Server

1. **Tanpa Terminal**: Tidak perlu menjalankan command CLI manual
2. **Real-time**: Akses langsung ke database production/staging
3. **Terintegrasi**: AI bisa melihat struktur dan menjalankan query
4. **Aman**: Menggunakan OAuth 2.1 untuk autentikasi

## Contoh Penggunaan

Setelah MCP aktif, AI bisa:
- Melihat semua tabel: "Tampilkan semua tabel di database"
- Melihat struktur tabel: "Tampilkan struktur tabel organization_members"
- Menjalankan query: "Jalankan query SELECT * FROM users WHERE active = true"
- Membuat migration: "Buat migration baru untuk menambah field X"

## Status Saat Ini

- ✅ Konfigurasi `.mcp.json` sudah benar
- ⏳ Menunggu restart IDE
- ⏳ Menunggu autentikasi OAuth

**Langkah Selanjutnya**: Restart IDE sekarang!
