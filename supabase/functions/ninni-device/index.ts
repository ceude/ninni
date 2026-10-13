// Ninni · "Cihaz ekle" (Supabase Edge Function: "ninni-device")
// create: oturum açık cihaz 10 dk geçerli, tek kullanımlık bir kod alır.
// redeem: yeni cihaz kodu verir → AYNI hesap için AYRI bir oturum açılır. Hiçbir cihaz kapanmaz.
// Şifre değiştirilmez (değişirse diğer cihazlar kapanırdı); her cihaz için tek kullanımlık giriş bağlantısı
// sunucuda üretilip hemen kullanılır, hiçbir e-posta gönderilmez.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { db: { schema: 'ninni' }, auth: { persistSession: false } });
const pub = () => createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), { auth: { persistSession: false } });

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const ALPHA = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const rand = (n: number, alpha = ALPHA) => { const b = crypto.getRandomValues(new Uint8Array(n)); return [...b].map(x => alpha[x % alpha.length]).join(''); };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  let body: { action?: string; code?: string } = {};
  try { body = await req.json(); } catch (_) { /* boş */ }

  if (body.action === 'create') {
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u, error } = await admin.auth.getUser(jwt);
    if (error || !u?.user) return json({ error: 'auth' }, 401);
    const { data: mem } = await db.from('members').select('family_id').eq('user_id', u.user.id).limit(1);
    if (!mem?.length) return json({ error: 'no family' }, 403);
    await db.from('device_codes').delete().eq('user_id', u.user.id).is('used_at', null); // eski kodları iptal et
    const code = rand(8);
    const { error: e2 } = await db.from('device_codes').insert({ code, user_id: u.user.id });
    if (e2) return json({ error: e2.message }, 500);
    return json({ code, expires_in: 600 });
  }

  if (body.action === 'redeem') {
    const code = String(body.code ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (code.length !== 8) return json({ error: 'code' }, 400);
    const { data: row } = await db.from('device_codes').select('*').eq('code', code).maybeSingle();
    if (!row || row.used_at || new Date(row.expires_at) < new Date()) return json({ error: 'invalid' }, 400);
    await db.from('device_codes').update({ used_at: new Date().toISOString() }).eq('code', code);

    const { data: got, error: ge } = await admin.auth.admin.getUserById(row.user_id);
    if (ge || !got?.user) return json({ error: 'user' }, 400);
    // ŞİFREYE DOKUNMA: şifre değişince Supabase diğer tüm oturumları kapatır.
    // Hesabın e-postası yoksa bir kez, hiç posta gönderilmeyen bir adres tanımlanır.
    let email = got.user.email;
    if (!email) {
      email = `u-${row.user_id}@devices.ninni.invalid`;
      const { error: ue } = await admin.auth.admin.updateUserById(row.user_id, { email, email_confirm: true });
      if (ue) return json({ error: 'email: ' + ue.message }, 500);
    }
    // Tek kullanımlık giriş bağlantısı üret (e-posta GÖNDERİLMEZ) ve hemen burada kullanarak yeni, ayrı bir oturum aç
    const { data: link, error: le } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
    if (le || !link?.properties?.hashed_token) return json({ error: 'link: ' + (le?.message ?? '') }, 500);
    let { data: s, error: se } = await pub().auth.verifyOtp({ token_hash: link.properties.hashed_token, type: 'magiclink' });
    if (se || !s?.session) {
      const { data: link2 } = await admin.auth.admin.generateLink({ type: 'magiclink', email });
      ({ data: s, error: se } = await pub().auth.verifyOtp({ token_hash: link2?.properties?.hashed_token ?? '', type: 'email' }));
    }
    if (se || !s?.session) return json({ error: 'verify: ' + (se?.message ?? '') }, 500);
    return json({ access_token: s.session.access_token, refresh_token: s.session.refresh_token });
  }

  return json({ error: 'action' }, 400);
});
