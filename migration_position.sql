-- Supabase > SQL Editor 에 붙여넣고 Run (schema.sql, migration_edit_delete.sql 실행 후 추가로 1회 실행)
-- 포스트잇 위치(책상 위 좌표, 0~100 %) 저장용 컬럼 + add_wish / edit_wish 교체

alter table public.wishes add column if not exists pos_x real not null default 50 check (pos_x between 0 and 100);
alter table public.wishes add column if not exists pos_y real not null default 50 check (pos_y between 0 and 100);

-- 기존 소원들이 한 곳에 겹치지 않도록 1회만 무작위로 흩뿌림
update public.wishes set pos_x = 10 + random()*80, pos_y = 10 + random()*80 where pos_x = 50 and pos_y = 50;

drop function if exists public.add_wish(text, text, text, text);
drop function if exists public.edit_wish(uuid, text, text, text, text);

create or replace function public.add_wish(p_nick text, p_content text, p_cheer text, p_client text, p_x real default 50, p_y real default 50)
returns public.wishes language plpgsql security definer set search_path = public as $$
declare r public.wishes;
begin
  if char_length(coalesce(p_client,'')) not between 16 and 64 then raise exception 'bad_client'; end if;
  perform _throttle('w:' || p_client, 3, interval '10 minutes');
  perform _throttle('w:all', 60, interval '1 minute');
  insert into wishes(nickname, content, cheer, pos_x, pos_y)
  values (coalesce(nullif(trim(p_nick),''), '익명'), trim(p_content), nullif(trim(p_cheer),''),
          least(100, greatest(0, coalesce(p_x,50))), least(100, greatest(0, coalesce(p_y,50))))
  returning * into r;
  insert into wish_owners(wish_id, owner_hash) values (r.id, _owner(p_client));
  return r;
end $$;

create or replace function public.edit_wish(p_id uuid, p_client text, p_nick text, p_content text, p_cheer text, p_x real default null, p_y real default null)
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
         cheer    = nullif(trim(p_cheer),''),
         pos_x    = coalesce(least(100, greatest(0, p_x)), pos_x),
         pos_y    = coalesce(least(100, greatest(0, p_y)), pos_y)
   where id = p_id
  returning * into r;
  return r;
end $$;

grant execute on function
  public.add_wish(text, text, text, text, real, real),
  public.edit_wish(uuid, text, text, text, text, real, real)
  to anon, authenticated;
