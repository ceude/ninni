-- Ninni · sunucu fonksiyonlarının (ninni-device, ninni-remind) ninni şemasına erişimi
-- SQL Editor'de bir kez çalıştır. Tekrar çalıştırmak güvenlidir.
grant usage on schema ninni to service_role;
grant all on all tables in schema ninni to service_role;
grant all on all functions in schema ninni to service_role;
alter default privileges in schema ninni grant all on tables to service_role;
alter default privileges in schema ninni grant all on functions to service_role;
