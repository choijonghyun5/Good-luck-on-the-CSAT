-- Supabase > SQL Editor 에 붙여넣고 Run (schema.sql 실행 후 추가로 1회 실행)
-- 소원 수정/삭제: 작성자(브라우저 client id)의 해시만 별도 테이블에 저장. 클라이언트는 이 테이블을 직접 읽을 수 없음.

create table if not exists public.wish_owners(
  wish_id uuid primary key references public.wishes on delete cascade,
  owner_hash text not null
);
create index if not exists wish_owners_hash_idx on public.wish_owners(owner_hash);
alter table public.wish_owners enable row level security;
revoke all on public.wish_owners from anon, authenticated;

create or replace function public._owner(p_client text) returns text
language sql immutable set search_path = public, extensions as
$$ select encode(digest('own:' || p_client, 'sha256'), 'hex') $$;
revoke execute on function public._owner from public, anon, authenticated;

-- 기존 add_wish 교체: 작성자 해시 저장 추가
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
  insert into wish_owners(wish_id, owner_hash) values (r.id, _owner(p_client));
  return r;
end $$;

create or replace function public.edit_wish(p_id uuid, p_client text, p_nick text, p_content text, p_cheer text)
returns public.wishes language plpgsql security definer set search_path = public as $$
declare r public.wishes;
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('e:' || p_client, 20, interval '10 minutes');
  if not exists (select 1 from wish_owners where wish_id = p_id and owner_hash = _owner(p_client)) then
    raise exception 'not_owner';
  end if;
  update wishes
     set nickname = coalesce(nullif(trim(p_nick),''), '익명'),
         content  = trim(p_content),
         cheer    = nullif(trim(p_cheer),'')
   where id = p_id
  returning * into r;
  return r;
end $$;

create or replace function public.delete_wish(p_id uuid, p_client text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('d:' || p_client, 20, interval '10 minutes');
  if not exists (select 1 from wish_owners where wish_id = p_id and owner_hash = _owner(p_client)) then
    raise exception 'not_owner';
  end if;
  delete from wishes where id = p_id;  -- wish_owners / wish_hearts 는 cascade 로 함께 삭제
  return true;
end $$;

create or replace function public.my_wish_ids(p_client text) returns setof uuid
language sql stable security definer set search_path = public as
$$ select wish_id from wish_owners where owner_hash = _owner(p_client) $$;

grant execute on function public.add_wish, public.edit_wish, public.delete_wish, public.my_wish_ids to anon, authenticated;
