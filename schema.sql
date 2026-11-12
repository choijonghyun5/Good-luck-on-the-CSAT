-- Supabase > SQL Editor 에 전체 붙여넣고 Run
create extension if not exists pgcrypto with schema extensions;

create table public.wishes(
  id uuid primary key default gen_random_uuid(),
  nickname text not null default '익명' check (char_length(nickname) between 1 and 20),
  content text not null check (char_length(content) between 1 and 300),
  cheer text check (cheer is null or char_length(cheer) <= 200),
  hearts int not null default 0,
  created_at timestamptz not null default now()
);
create table public.wish_hearts(
  wish_id uuid not null references public.wishes on delete cascade,
  client_id text not null check (char_length(client_id) between 16 and 64),
  primary key (wish_id, client_id)
);
create table public.rate_log(id bigserial primary key, key text not null, created_at timestamptz not null default now());
create index on public.rate_log(key, created_at);
create table public.letters(
  id uuid primary key default gen_random_uuid(),
  nickname text not null check (char_length(nickname) between 1 and 20),
  title text not null check (char_length(title) between 1 and 60),
  body text not null check (char_length(body) between 1 and 3000),
  instagram text check (instagram is null or instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  access_hash text not null unique,
  delivered boolean not null default false,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);
create table public.admins(user_id uuid primary key references auth.users on delete cascade);

alter table public.wishes enable row level security;
alter table public.wish_hearts enable row level security;
alter table public.rate_log enable row level security;
alter table public.letters enable row level security;
alter table public.admins enable row level security;

revoke all on all tables in schema public from anon, authenticated;
grant select on public.wishes to anon, authenticated;
grant select on public.letters to authenticated;
grant update (delivered, delivered_at) on public.letters to authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.admins where user_id = auth.uid()) $$;

create policy "wishes_read" on public.wishes for select to anon, authenticated using (true);
create policy "letters_admin_read" on public.letters for select to authenticated using (public.is_admin());
create policy "letters_admin_update" on public.letters for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- wish_hearts / rate_log / admins: 정책 없음 = 클라이언트 접근 전면 차단 (아래 RPC로만 조작)

create or replace function public._throttle(p_key text, p_max int, p_window interval) returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from rate_log where key = p_key and created_at > now() - p_window) >= p_max then
    raise exception 'rate_limit';
  end if;
  insert into rate_log(key) values (p_key);
  delete from rate_log where created_at < now() - interval '2 days';
end $$;
revoke execute on function public._throttle from public, anon, authenticated;

create or replace function public.add_wish(p_nick text, p_content text, p_cheer text, p_client text)
returns public.wishes language plpgsql security definer set search_path = public as $$
declare r public.wishes;
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('w:' || p_client, 3, interval '10 minutes');
  perform _throttle('w:all', 60, interval '1 minute');
  insert into wishes(nickname, content, cheer)
  values (coalesce(nullif(trim(p_nick),''), '익명'), trim(p_content), nullif(trim(p_cheer),''))
  returning * into r;
  return r;
end $$;

create or replace function public.add_heart(p_wish uuid, p_client text) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('h:' || p_client, 60, interval '1 minute');
  insert into wish_hearts(wish_id, client_id) values (p_wish, p_client) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 1 then update wishes set hearts = hearts + 1 where id = p_wish; end if;
  return n = 1;
end $$;

create or replace function public.get_stats() returns table(wish_count bigint, heart_count bigint)
language sql stable security definer set search_path = public as
$$ select count(*), coalesce(sum(hearts),0)::bigint from wishes $$;

create or replace function public.submit_letter(p_nick text, p_title text, p_body text, p_insta text, p_client text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare code text;
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('l:' || p_client, 3, interval '1 hour');
  perform _throttle('l:all', 60, interval '1 minute');
  code := upper(encode(gen_random_bytes(8), 'hex'));
  insert into letters(nickname, title, body, instagram, access_hash)
  values (trim(p_nick), trim(p_title), trim(p_body), nullif(ltrim(trim(coalesce(p_insta,'')), '@'), ''),
          encode(digest(code, 'sha256'), 'hex'));
  return substr(code,1,4)||'-'||substr(code,5,4)||'-'||substr(code,9,4)||'-'||substr(code,13,4);
end $$;

create or replace function public.get_my_letter(p_code text)
returns table(nickname text, title text, body text, instagram text, created_at timestamptz, delivered boolean)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _throttle('g:all', 120, interval '1 minute');
  return query select l.nickname, l.title, l.body, l.instagram, l.created_at, l.delivered
  from letters l where l.access_hash = encode(digest(upper(replace(trim(p_code),'-','')), 'sha256'), 'hex');
end $$;

grant execute on function public.add_wish, public.add_heart, public.get_stats,
  public.submit_letter, public.get_my_letter, public.is_admin to anon, authenticated;

alter publication supabase_realtime add table public.wishes;
