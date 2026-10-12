-- Ninni · "Cihaz ekle" kodları (sadece sunucu fonksiyonu "ninni-device" kullanır)
-- SQL Editor'de bir kez çalıştır. Tekrar çalıştırmak güvenlidir.
create table if not exists ninni.device_codes (
  code text primary key,
  user_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at timestamptz
);
alter table ninni.device_codes enable row level security; -- politika yok: uygulama doğrudan erişemez
revoke all on ninni.device_codes from anon, authenticated;
