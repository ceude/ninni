// Ninni · ebeveynden ebeveyne anlık bildirim (Supabase Edge Function: "ninni-notify")
// Şimdilik: market listesindeki alınmamış ürünleri ailedeki DİĞER ebeveyn(ler)e gönderir.
// Çağıran kullanıcının oturumu doğrulanır; sadece o ailenin ebeveyni gönderebilir.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) ?? '';
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { db: { schema: 'ninni' }, auth: { persistSession: false } });
webpush.setVapidDetails(env('VAPID_SUBJECT'), env('VAPID_PUBLIC'), env('VAPID_PRIVATE'));

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const { data: u, error } = await admin.auth.getUser(jwt);
  if (error || !u?.user) return json({ error: 'auth' }, 401);
  let body: { family_id?: string; kind?: string } = {};
  try { body = await req.json(); } catch (_) { /* boş */ }
  const fam = String(body.family_id ?? '');

  const { data: members } = await db.from('members').select('user_id, role, display_name').eq('family_id', fam);
  const me = (members ?? []).find(m => m.user_id === u.user.id);
  if (!me || me.role !== 'parent') return json({ error: 'not parent' }, 403);
  const others = (members ?? []).filter(m => m.role === 'parent' && m.user_id !== u.user.id);
  if (!others.length) return json({ ok: true, sent: 0, reason: 'no partner' });

  if (body.kind !== 'shop') return json({ error: 'kind' }, 400);
  const { data: items } = await db.from('entries').select('data, ts').eq('family_id', fam).eq('kind', 'shop').eq('deleted', false).order('ts');
  const open = (items ?? []).filter(i => !i.data?.checked).map(i => String(i.data?.title ?? '')).filter(Boolean);
  if (!open.length) return json({ ok: true, sent: 0, reason: 'empty' });
  const list = open.slice(0, 5).join(', ') + (open.length > 5 ? ` +${open.length - 5}` : '');
  const payload = JSON.stringify({ title: `🛒 Market listesi · ${open.length} ürün`, body: `${me.display_name}: ${list}`, tag: 'ninni-shop', url: './?tab=list' });

  const { data: subs } = await db.from('push_subs').select('*').eq('family_id', fam).in('user_id', others.map(o => o.user_id));
  let sent = 0;
  for (const s of subs ?? []) {
    try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 6 * 3600, urgency: 'high' }); sent++; }
    catch (e) { const code = (e as { statusCode?: number }).statusCode; if (code === 404 || code === 410) await db.from('push_subs').delete().eq('endpoint', s.endpoint); }
  }
  return json({ ok: true, sent, to: others.map(o => o.display_name), reason: sent ? undefined : 'no subscription' });
});
