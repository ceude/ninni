-- Ninni · bir ebeveynin aileyi tamamen silebilmesi (kayıtlar + fotoğraflar)
-- SQL Editor'de bir kez çalıştır. Tekrar çalıştırmak güvenlidir.

-- Ebeveyn kendi ailesinin klasöründeki fotoğrafları silebilsin
drop policy if exists ninni_delete on storage.objects;
create policy ninni_delete on storage.objects for delete to authenticated
  using (bucket_id = 'ninni' and exists (
    select 1 from ninni.members m
    where m.family_id::text = (storage.foldername(name))[1] and m.user_id = auth.uid() and m.role = 'parent'));

-- Aileyi sil: üyeler, bebekler, tüm kayıtlar, davetler, izinler (cascade)
create or replace function ninni.delete_family(p_family uuid)
returns void language plpgsql security definer set search_path = ninni, public as $$
begin
  if not ninni.is_parent(p_family) then raise exception 'not parent'; end if;
  delete from ninni.families where id = p_family;
end $$;
grant execute on function ninni.delete_family(uuid) to authenticated;
