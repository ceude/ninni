// Ninni · hatırlatıcı bildirimleri (Supabase Edge Function: "ninni-remind")
// Her saat başı pg_cron tarafından çağrılır. Hatırlatıcının saatlerinden birindeysek ve
// o gün "verildi" işaretlenmemişse, ailenin SADECE ebeveynlerine push bildirimi gönderir.
// Test: ?test=<family_id> → saate bakmadan o aileye hemen gönderir (yine "verildi" ise göndermez).
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const env = (k: string) => Deno.env.get(k) ?? '';
const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { db: { schema: 'ninni' }, auth: { persistSession: false } });
webpush.setVapidDetails(env('VAPID_SUBJECT'), env('VAPID_PUBLIC'), env('VAPID_PRIVATE'));

function localNow(tz: string) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' })
    .formatToParts(new Date()).map(x => [x.type, x.value]));
  return { day: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) };
}

Deno.serve(async (req) => {
  if (req.headers.get('x-cron-secret') !== env('CRON_SECRET')) return new Response('unauthorized', { status: 401 });
  const test = new URL(req.url).searchParams.get('test');
  const log: unknown[] = [];

  const { data: rems, error } = await sb.from('entries').select('id, family_id, baby_id, data').eq('kind', 'reminder').eq('deleted', false);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  for (const r of rems ?? []) {
    const d = r.data ?? {};
    if (d.active === false) continue;
    const { day, hour } = localNow(d.tz || 'Europe/Berlin');
    const hours: number[] = Array.isArray(d.hours) ? d.hours.map(Number) : [];
    if (test ? test !== r.family_id : !hours.includes(hour)) continue;

    const { data: given } = await sb.from('entries').select('id').eq('kind', 'dose').eq('deleted', false)
      .eq('data->>rid', r.id).eq('data->>day', day).limit(1);
    if (given?.length) { log.push({ rid: r.id, skip: 'verildi' }); continue; }

    const { data: parents } = await sb.from('members').select('user_id').eq('family_id', r.family_id).eq('role', 'parent');
    const ids = (parents ?? []).map(p => p.user_id);
    if (!ids.length) continue;
    const { data: subs } = await sb.from('push_subs').select('*').eq('family_id', r.family_id).in('user_id', ids);

    let babyName = '';
    if (r.baby_id) { const { data: b } = await sb.from('babies').select('name').eq('id', r.baby_id).single(); babyName = b?.name ?? ''; }
    const title = `💊 ${d.title || 'Hatırlatıcı'} zamanı`;
    const body = `${babyName || 'Minik'} bugünkü ${(d.title || 'ilaç').toLocaleLowerCase('tr')} dozunu aldı mı? Verdiyseniz Ninni'de "Verildi"ye dokunun 🤍`;
    const payload = JSON.stringify({ title, body, tag: 'ninni-' + r.id, url: './' });

    for (const s of subs ?? []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600, urgency: 'high' });
        log.push({ rid: r.id, sent: s.endpoint.slice(0, 40) });
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await sb.from('push_subs').delete().eq('endpoint', s.endpoint); // abonelik geçersiz
        log.push({ rid: r.id, fail: code ?? String(e) });
      }
    }
  }
  return Response.json({ ok: true, at: new Date().toISOString(), log });
});
