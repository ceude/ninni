# Ninni · Minik Defter

Bebek ve ebeveyn PWA'sı. Her küçük kayıt kendiliğinden bir hatıraya dönüşür.
Dosyalar: `index.html` (tüm uygulama), `sw.js`, `manifest.json`, ikonlar, `supabase/schema.sql`.

## 1 · Supabase (Şampiyonlar Ligi projesinde, ayrı `ninni` şeması)

1. **SQL Editor** → `supabase/schema.sql` içeriğini yapıştır → Run. Mevcut tablolara dokunmaz.
2. **Project Settings → Data API → Exposed schemas** → `ninni` ekle.
3. **Authentication → Sign In / Providers** → **Allow anonymous sign-ins** aç.
4. **Authentication → URL Configuration** → Redirect URLs'e yayın adresini ekle (ör. `https://ceude.github.io/ninni/`).
5. `index.html` başındaki `CONFIG` içine **Project URL** ve **anon / publishable key** yaz. Bu anahtar gizli değildir; RLS korur. `service_role` anahtarını asla koyma.

İsteğe bağlı, Google ile bağlama (kalıcı hesap):
- Authentication → Providers → Google: Google Cloud'da OAuth istemcisi aç, ID ve secret'ı gir.
- Authentication → **Allow manual linking** aç.
- `CONFIG.GOOGLE = true` yap.

> Supabase bilgileri boşken uygulama tamamen telefonda çalışır. Bilgiler sonradan eklenince
> o güne kadarki her şey (fotoğraflar dahil) otomatik olarak aileye taşınır.

## 1b · Hatırlatıcı bildirimleri (demir vb.)

1. SQL Editor → `supabase/02-hatirlatici.sql` → Run.
2. Edge Functions → Deploy a new function → **Via Editor** → adı `ninni-remind` → `supabase/functions/ninni-remind/index.ts` içeriğini yapıştır → Deploy.
   Fonksiyonun ayarlarında **Verify JWT** kapalı olmalı. Fonksiyon kendi `x-cron-secret` başlığını kontrol eder.
3. Edge Functions → Secrets: `VAPID_PUBLIC`, `VAPID_PRIVATE`, `VAPID_SUBJECT`, `CRON_SECRET` (değerler GitHub'a konmaz).
4. SQL Editor → saatlik cron (pg_cron + pg_net) ile fonksiyonu her saat başı çağır.
5. Uygulamada: Bebek sekmesi → 💊 Hatırlatıcılar → ekle. **Her ebeveyn** kendi telefonunda "Bildirimleri aç"a dokunur.
   iPhone'da bildirim yalnızca ana ekrana eklenmiş Ninni'de çalışır (iOS 16.4+).

## 1c · Cihaz ekle (aynı hesap telefonda + bilgisayarda)

1. SQL Editor → `supabase/05-cihaz-ekle.sql` → Run.
2. Edge Functions → yeni fonksiyon `ninni-device` → `supabase/functions/ninni-device/index.ts` → Deploy → **Verify JWT kapalı**.
3. Uygulamada: Ben → **Cihaz ekle** → 8 haneli kod (10 dk, tek kullanımlık).
   Yeni cihazda "Bu hesap başka cihazımda açık" → kod. İki cihaz da açık kalır.

Aile silme için: `supabase/04-aile-silme.sql`.

## 2 · GitHub Pages

Repo (ör. `ceude/ninni`) → bu dosyaları köke koy → Settings → Pages → Branch: `main` / root.
Güncelleme yaptığında `sw.js` içindeki `VERSION`'ı artır ki telefonlar yeni sürümü alsın.

## 3 · Telefona kurulum

- **iPhone:** Safari'de aç → Paylaş → **Ana Ekrana Ekle** → ana ekrandaki Ninni'den aç.
  Ana ekrana eklenmeyen sitelerin verisini iOS silebilir. Uygulama bu yüzden ilk açılışta nazikçe yönlendirir.
- **Eşini / sevdiklerini davet:** Ben → Aile → Davet → link veya QR.
  iPhone'da davet edilen kişi Ninni'yi ana ekrana ekleyip oradan açar, sonra **"Davet kodum var"**a dokunup kodu yazar.

## Gizlilik ve izinler (RLS)

| Veri | Ebeveynler | Sevenler (teyze vb.) |
|---|---|---|
| Anılar, ilkler, aylık foto, mektuplar | ✓ | ✓ (kendi notlarını da bırakır) |
| Uyku / beslenme / bez | ✓ | Ebeveyn kişi bazında açarsa |
| Boy-kilo | Geçmiş + eğri | Sadece son ölçüm (geçmiş ebeveyn açarsa) |
| Termin, market listesi | ✓ | — |
| İstek listesi | ✓ (gizli alıcıyı göremez) | ✓ + "Ben alıyorum", "adımı gizle" |
| Ebeveynin kendi günü | Sadece kendisi (paylaşırsa eşi görür/düzenler) | — |
| Haftalık check-in | Sadece kendisi, hiçbir zaman paylaşılmaz | — |

Analitik yok. Fotoğraflar telefonda ~1600 px'e küçültülüp saklanır; asıllar galeride kalmalı.

## Kaynaklar

- Büyüme: WHO Child Growth Standards aylık LMS tabloları (0–60 ay)
- U1–U9: G-BA Kinder-Richtlinie
- Aşılar: STIKO Impfkalender 2026 (Epid. Bull. 4/2026)

STIKO tarihleri her yıl güncellenir; `VACCINES` dizisini yılda bir kontrol et.
