create schema storage;
create table storage.buckets(id text primary key, name text, public boolean);
create table storage.objects(id uuid default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create function storage.foldername(n text) returns text[] language sql immutable as $$ select (string_to_array(n,'/'))[1:array_length(string_to_array(n,'/'),1)-1] $$;
grant usage on schema storage to authenticated; grant select,insert,delete on storage.objects to authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
-- mirror Supabase: service_role has full table/function privileges (it also bypasses RLS)
grant usage on schema public, auth to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;
grant select on auth.users to service_role;
