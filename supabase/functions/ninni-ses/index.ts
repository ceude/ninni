// Ninni · ses anısı bağlantısı (Supabase Edge Function: "ninni-ses")
// Mektuptaki / yıl kitabındaki QR → bu fonksiyon → 1 saatlik imzalı ses bağlantısına yönlendirir.
// Kodu bilen (QR'ı okutan) dinleyebilir; anı silinirse bağlantı çalışmaz. "Verify JWT" KAPALI olmalı.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) ?? '';
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { db: { schema: 'ninni' }, auth: { persistSession: false } });
const store = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const text = (s: string, status = 200) => new Response(s, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });

Deno.serve(async (req) => {
  const k = (new URL(req.url).searchParams.get('k') ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (k.length < 8) return text('Ses bulunamadı.', 404);
  const { data } = await db.from('entries').select('data').eq('kind', 'voice').eq('deleted', false).eq('data->>audio_code', k).limit(1);
  const path = data?.[0]?.data?.audio_path;
  if (!path) return text('Bu ses artık paylaşılmıyor. 🤍', 404);
  const { data: s, error } = await store.storage.from('ninni').createSignedUrl(path, 3600);
  if (error || !s?.signedUrl) return text('Ses şu an açılamadı, biraz sonra tekrar dene.', 500);
  return Response.redirect(s.signedUrl, 302);
});
