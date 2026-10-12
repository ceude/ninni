-- Ninni · hatırlatıcılar (demir vb.) + push abonelikleri
-- SQL Editor'de bir kez çalıştır. Tekrar çalıştırmak güvenlidir.

-- Her telefonun push aboneliği (sadece ebeveynler)
create table if not exists ninni.push_subs (
  endpoint text primary key,
  family_id uuid not null,
  user_id uuid not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  foreign key (family_id, user_id) references ninni.members (family_id, user_id) on delete cascade
);
alter table ninni.push_subs enable row level security;
drop policy if exists push_sel on ninni.push_subs;
create policy push_sel on ninni.push_subs for select to authenticated using (user_id = auth.uid());
drop policy if exists push_ins on ninni.push_subs;
create policy push_ins on ninni.push_subs for insert to authenticated with check (user_id = auth.uid() and ninni.is_parent(family_id));
drop policy if exists push_upd on ninni.push_subs;
create policy push_upd on ninni.push_subs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and ninni.is_parent(family_id));
drop policy if exists push_del on ninni.push_subs;
create policy push_del on ninni.push_subs for delete to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on ninni.push_subs to authenticated;

-- Hatırlatıcı tanımları ("reminder") ve "verildi" kayıtları ("dose") sevenlere görünmez
create or replace function ninni.entry_visible(p_family uuid, p_owner uuid, p_subject text, p_kind text, p_id uuid, p_baby uuid)
returns boolean language sql stable security definer set search_path = ninni, public as $$
  select case
    when not ninni.is_member(p_family) then false
    when p_subject = 'self' then
      p_owner = auth.uid() or (p_kind <> 'checkin' and ninni.has_self_grant(p_family, p_owner, 'self_view'))
    when ninni.is_parent(p_family) then true
    when p_kind in ('shop','appt','letternote','reminder') then false
    when p_kind in ('feed','sleep','diaper','potty','dose') then ninni.has_family_grant(p_family, 'care')
    when p_kind = 'growth' then ninni.has_family_grant(p_family, 'growth_history') or ninni.is_latest_growth(p_id, p_baby)
    else true
  end
$$;

create index if not exists entries_kind on ninni.entries (kind) where not deleted;
