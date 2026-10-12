-- Ninni · Supabase şeması
-- Şampiyonlar Ligi projesine dokunmaz: her şey ayrı "ninni" şemasında.
-- SQL Editor'de bir kez çalıştır. Tekrar çalıştırmak güvenlidir (idempotent).

create schema if not exists ninni;
grant usage on schema ninni to anon, authenticated;

-- ───────────────────────── tablolar
create table if not exists ninni.families (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists ninni.members (
  family_id uuid not null references ninni.families on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role text not null check (role in ('parent','loved')),
  parent_kind text check (parent_kind in ('anne','baba')),
  display_name text not null,
  relation text,
  show_awake boolean not null default true,
  last_active timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (family_id, user_id)
);

create table if not exists ninni.babies (
  id uuid primary key,
  family_id uuid not null references ninni.families on delete cascade,
  name text,
  sex text not null default 'unknown' check (sex in ('girl','boy','unknown')),
  status text not null default 'born' check (status in ('born','expected')),
  birth_date date,
  due_date date,
  photo_path text,
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- scope: care | growth_history  → ebeveynin bir sevene verdiği aile izni
--        self_view | self_edit  → ebeveynin kendi kayıtları için verdiği izin
create table if not exists ninni.grants (
  family_id uuid not null references ninni.families on delete cascade,
  grantor uuid not null references auth.users on delete cascade,
  grantee uuid not null references auth.users on delete cascade,
  scope text not null check (scope in ('care','growth_history','self_view','self_edit')),
  created_at timestamptz not null default now(),
  primary key (family_id, grantor, grantee, scope)
);

create table if not exists ninni.invites (
  code text primary key,
  family_id uuid not null references ninni.families on delete cascade,
  role text not null check (role in ('parent','loved')),
  relation text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days',
  used_by uuid,
  used_at timestamptz
);

-- Tüm kayıtlar: beslenme, uyku, bez, an, ilk, büyüme, termin, istek, market, ebeveynin kendi günü...
create table if not exists ninni.entries (
  id uuid primary key,
  family_id uuid not null references ninni.families on delete cascade,
  baby_id uuid references ninni.babies on delete cascade,
  owner_id uuid not null references auth.users on delete cascade,
  subject text not null default 'baby' check (subject in ('baby','self')),
  kind text not null,
  ts timestamptz not null,
  end_ts timestamptz,
  data jsonb not null default '{}'::jsonb,
  photo_path text,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists entries_family_updated on ninni.entries (family_id, updated_at);
create index if not exists entries_baby_kind_ts on ninni.entries (baby_id, kind, ts);

create table if not exists ninni.wish_res (
  entry_id uuid primary key references ninni.entries on delete cascade,
  family_id uuid not null references ninni.families on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);

-- ───────────────────────── updated_at
create or replace function ninni.touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

do $$ declare t text; begin
  foreach t in array array['families','members','babies','entries'] loop
    execute format('drop trigger if exists touch on ninni.%I', t);
    execute format('create trigger touch before insert or update on ninni.%I for each row execute function ninni.touch()', t);
  end loop;
end $$;

-- ───────────────────────── yardımcı fonksiyonlar
create or replace function ninni.is_member(p_family uuid) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select exists (select 1 from ninni.members where family_id = p_family and user_id = auth.uid())
$$;

create or replace function ninni.is_member_text(p text) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select exists (select 1 from ninni.members where family_id::text = p and user_id = auth.uid())
$$;

create or replace function ninni.is_parent(p_family uuid) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select exists (select 1 from ninni.members where family_id = p_family and user_id = auth.uid() and role = 'parent')
$$;

create or replace function ninni.has_family_grant(p_family uuid, p_scope text) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select exists (select 1 from ninni.grants where family_id = p_family and grantee = auth.uid() and scope = p_scope)
$$;

create or replace function ninni.has_self_grant(p_family uuid, p_owner uuid, p_scope text) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select exists (select 1 from ninni.grants
    where family_id = p_family and grantor = p_owner and grantee = auth.uid()
      and (scope = p_scope or (p_scope = 'self_view' and scope = 'self_edit')))
$$;

create or replace function ninni.is_latest_growth(p_id uuid, p_baby uuid) returns boolean
language sql stable security definer set search_path = ninni, public as $$
  select not exists (
    select 1 from ninni.entries e2, ninni.entries e1
    where e1.id = p_id and e2.baby_id = p_baby and e2.kind = 'growth'
      and not e2.deleted and e2.ts > e1.ts)
$$;

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

create or replace function ninni.entry_editable(p_family uuid, p_owner uuid, p_subject text, p_kind text)
returns boolean language sql stable security definer set search_path = ninni, public as $$
  select case
    when not ninni.is_member(p_family) then false
    when p_subject = 'self' then
      p_owner = auth.uid() or (p_kind <> 'checkin' and ninni.has_self_grant(p_family, p_owner, 'self_edit'))
    when ninni.is_parent(p_family) then true
    else p_owner = auth.uid() and p_kind = 'note'
  end
$$;

-- ───────────────────────── RLS
alter table ninni.families enable row level security;
alter table ninni.members  enable row level security;
alter table ninni.babies   enable row level security;
alter table ninni.grants   enable row level security;
alter table ninni.invites  enable row level security;
alter table ninni.entries  enable row level security;
alter table ninni.wish_res enable row level security;

drop policy if exists fam_sel on ninni.families;
create policy fam_sel on ninni.families for select to authenticated using (ninni.is_member(id));

drop policy if exists mem_sel on ninni.members;
create policy mem_sel on ninni.members for select to authenticated using (ninni.is_member(family_id));
drop policy if exists mem_upd on ninni.members;
create policy mem_upd on ninni.members for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists baby_sel on ninni.babies;
create policy baby_sel on ninni.babies for select to authenticated using (ninni.is_member(family_id));
drop policy if exists baby_ins on ninni.babies;
create policy baby_ins on ninni.babies for insert to authenticated with check (ninni.is_parent(family_id));
drop policy if exists baby_upd on ninni.babies;
create policy baby_upd on ninni.babies for update to authenticated using (ninni.is_parent(family_id)) with check (ninni.is_parent(family_id));

drop policy if exists grant_sel on ninni.grants;
create policy grant_sel on ninni.grants for select to authenticated using (ninni.is_member(family_id));
drop policy if exists grant_ins on ninni.grants;
create policy grant_ins on ninni.grants for insert to authenticated with check (
  grantor = auth.uid() and ninni.is_parent(family_id)
  and exists (select 1 from ninni.members m where m.family_id = grants.family_id and m.user_id = grants.grantee));
drop policy if exists grant_del on ninni.grants;
create policy grant_del on ninni.grants for delete to authenticated using (
  grantor = auth.uid() or (scope in ('care','growth_history') and ninni.is_parent(family_id)));

drop policy if exists ent_sel on ninni.entries;
create policy ent_sel on ninni.entries for select to authenticated
  using (ninni.entry_visible(family_id, owner_id, subject, kind, id, baby_id));
drop policy if exists ent_ins on ninni.entries;
create policy ent_ins on ninni.entries for insert to authenticated with check (
  owner_id = auth.uid() and ninni.is_member(family_id) and (
    ninni.is_parent(family_id) or (subject = 'baby' and kind = 'note')));
drop policy if exists ent_upd on ninni.entries;
create policy ent_upd on ninni.entries for update to authenticated
  using (ninni.entry_editable(family_id, owner_id, subject, kind))
  with check (ninni.entry_editable(family_id, owner_id, subject, kind));
-- silme yok: kayıtlar "deleted" bayrağıyla yumuşak silinir. invites / wish_res sadece RPC ile.

-- Üye kendi satırında sadece bu kolonları değiştirebilir (rol yükseltme yok)
revoke all on ninni.families, ninni.members, ninni.babies, ninni.grants, ninni.invites, ninni.entries, ninni.wish_res from anon, authenticated;
grant select on ninni.families, ninni.members, ninni.babies, ninni.grants, ninni.entries to authenticated;
grant update (display_name, parent_kind, relation, show_awake, last_active) on ninni.members to authenticated;
grant insert, update on ninni.babies, ninni.entries to authenticated;
grant insert, delete on ninni.grants to authenticated;

-- ───────────────────────── RPC
create or replace function ninni.gen_code() returns text language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
  from generate_series(1, 8)
$$;

create or replace function ninni.create_family(p_name text, p_parent_kind text, p_baby jsonb)
returns uuid language plpgsql security definer set search_path = ninni, public as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  insert into ninni.families (created_by) values (auth.uid()) returning id into fid;
  insert into ninni.members (family_id, user_id, role, parent_kind, display_name)
    values (fid, auth.uid(), 'parent', p_parent_kind, p_name);
  insert into ninni.babies (id, family_id, name, sex, status, birth_date, due_date, data)
    values ((p_baby->>'id')::uuid, fid, p_baby->>'name', coalesce(p_baby->>'sex','unknown'),
            coalesce(p_baby->>'status','born'), (p_baby->>'birth_date')::date, (p_baby->>'due_date')::date,
            coalesce(p_baby->'data','{}'::jsonb));
  return fid;
end $$;

create or replace function ninni.create_invite(p_family uuid, p_role text, p_relation text)
returns text language plpgsql security definer set search_path = ninni, public as $$
declare c text;
begin
  if not ninni.is_parent(p_family) then raise exception 'not parent'; end if;
  loop
    c := ninni.gen_code();
    exit when not exists (select 1 from ninni.invites where code = c);
  end loop;
  insert into ninni.invites (code, family_id, role, relation) values (c, p_family, p_role, p_relation);
  return c;
end $$;

create or replace function ninni.invite_info(p_code text)
returns table (family_id uuid, role text, relation text, baby_name text, inviter text, valid boolean)
language sql stable security definer set search_path = ninni, public as $$
  select i.family_id, i.role, i.relation,
    (select b.name from ninni.babies b where b.family_id = i.family_id and not b.deleted order by b.created_at limit 1),
    (select m.display_name from ninni.members m where m.family_id = i.family_id and m.user_id = i.created_by),
    (i.used_by is null and i.expires_at > now())
  from ninni.invites i where i.code = upper(replace(p_code, '-', ''))
$$;

create or replace function ninni.join_family(p_code text, p_name text, p_parent_kind text, p_relation text)
returns uuid language plpgsql security definer set search_path = ninni, public as $$
declare inv ninni.invites;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  select * into inv from ninni.invites where code = upper(replace(p_code, '-', '')) for update;
  if inv is null then raise exception 'invite not found'; end if;
  if exists (select 1 from ninni.members where family_id = inv.family_id and user_id = auth.uid()) then
    return inv.family_id;
  end if;
  if inv.used_by is not null or inv.expires_at < now() then raise exception 'invite used'; end if;
  insert into ninni.members (family_id, user_id, role, parent_kind, display_name, relation)
    values (inv.family_id, auth.uid(), inv.role,
            case when inv.role = 'parent' then p_parent_kind end, p_name,
            coalesce(nullif(p_relation, ''), inv.relation));
  update ninni.invites set used_by = auth.uid(), used_at = now() where code = inv.code;
  return inv.family_id;
end $$;

create or replace function ninni.remove_member(p_family uuid, p_user uuid)
returns void language plpgsql security definer set search_path = ninni, public as $$
begin
  if not (ninni.is_parent(p_family) or p_user = auth.uid()) then raise exception 'not allowed'; end if;
  delete from ninni.grants where family_id = p_family and (grantee = p_user or grantor = p_user);
  delete from ninni.members where family_id = p_family and user_id = p_user;
end $$;

create or replace function ninni.wish_status(p_family uuid)
returns table (entry_id uuid, reserved_by uuid, mine boolean, hidden boolean)
language sql stable security definer set search_path = ninni, public as $$
  select r.entry_id,
    case when r.user_id = auth.uid() or not r.hidden then r.user_id end,
    r.user_id = auth.uid(), r.hidden
  from ninni.wish_res r where r.family_id = p_family and ninni.is_member(p_family)
$$;

create or replace function ninni.reserve_wish(p_entry uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = ninni, public as $$
declare fid uuid;
begin
  select family_id into fid from ninni.entries where id = p_entry and kind = 'wish' and not deleted;
  if fid is null or not ninni.is_member(fid) then raise exception 'not allowed'; end if;
  insert into ninni.wish_res (entry_id, family_id, user_id, hidden) values (p_entry, fid, auth.uid(), p_hidden)
  on conflict (entry_id) do update set hidden = excluded.hidden where ninni.wish_res.user_id = auth.uid();
end $$;

create or replace function ninni.unreserve_wish(p_entry uuid)
returns void language sql security definer set search_path = ninni, public as $$
  delete from ninni.wish_res where entry_id = p_entry and user_id = auth.uid()
$$;

grant execute on all functions in schema ninni to authenticated;
revoke execute on function ninni.gen_code() from authenticated;

-- ───────────────────────── Storage (özel bucket, yol: <family_id>/<dosya>)
insert into storage.buckets (id, name, public) values ('ninni', 'ninni', false) on conflict (id) do nothing;

drop policy if exists ninni_read on storage.objects;
create policy ninni_read on storage.objects for select to authenticated
  using (bucket_id = 'ninni' and ninni.is_member_text((storage.foldername(name))[1]));
drop policy if exists ninni_write on storage.objects;
create policy ninni_write on storage.objects for insert to authenticated
  with check (bucket_id = 'ninni' and ninni.is_member_text((storage.foldername(name))[1]));

-- Aynı projedeki başka (geniş) storage kuralları "ninni" bucket'ına kapı açamasın:
-- RESTRICTIVE kural diğer kurallarla VE'lenir; başka bucket'ları etkilemez.
grant execute on function ninni.is_member_text(text) to anon; -- girişsiz istekte de kural değerlendirilebilsin (false döner)
drop policy if exists ninni_guard on storage.objects;
create policy ninni_guard on storage.objects as restrictive for all to public
  using (bucket_id <> 'ninni' or ninni.is_member_text((storage.foldername(name))[1]))
  with check (bucket_id <> 'ninni' or ninni.is_member_text((storage.foldername(name))[1]));

-- ───────────────────────── Push abonelikleri (hatırlatıcılar) → ayrıntı: 02-hatirlatici.sql
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

-- ───────────────────────── Realtime (market listesi, gece nöbeti anlık)
do $$ begin
  begin alter publication supabase_realtime add table ninni.entries; exception when others then null; end;
  begin alter publication supabase_realtime add table ninni.members; exception when others then null; end;
  begin alter publication supabase_realtime add table ninni.babies;  exception when others then null; end;
end $$;
