-- Kindle backend. Paste into Supabase: SQL Editor > New query > Run.

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  birthdate date not null check (birthdate <= current_date - interval '18 years'),
  intent text not null default 'Casual' check (intent in ('Serious','Casual','Friends')),
  prompt_q text, prompt_a text check (char_length(prompt_a) <= 300),
  interests text[] not null default '{}',
  photo_path text,
  created_at timestamptz not null default now()
);

create table swipes (
  swiper uuid not null references profiles on delete cascade,
  target uuid not null references profiles on delete cascade,
  kind text not null check (kind in ('like','nope','super')),
  created_at timestamptz not null default now(),
  primary key (swiper, target),
  check (swiper <> target)
);

create table matches (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references profiles on delete cascade,
  user_b uuid not null references profiles on delete cascade,
  created_at timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);

create table messages (
  id bigint generated always as identity primary key,
  match_id uuid not null references matches on delete cascade,
  sender uuid not null references profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index on messages (match_id, created_at);

create table blocks (
  blocker uuid not null references profiles on delete cascade,
  blocked uuid not null references profiles on delete cascade,
  primary key (blocker, blocked)
);

create table reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references profiles on delete cascade,
  reported uuid not null references profiles on delete cascade,
  reason text not null check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);

-- Creates a match when two people like each other.
create function make_match() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind in ('like','super') and exists (
    select 1 from swipes where swiper = new.target and target = new.swiper and kind in ('like','super')
  ) then
    insert into matches (user_a, user_b)
    values (least(new.swiper, new.target), greatest(new.swiper, new.target))
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger on_swipe after insert on swipes for each row execute function make_match();

-- Helper: is the current user part of this match?
create function in_match(m uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from matches where id = m and auth.uid() in (user_a, user_b))
$$;

-- Discover feed: people you haven't swiped on yet (blocked users are hidden by the profiles policy).
create function discover(p_intent text default null) returns setof profiles
language sql stable security invoker as $$
  select p.* from profiles p
  where p.id <> auth.uid()
    and not exists (select 1 from swipes s where s.swiper = auth.uid() and s.target = p.id)
    and (p_intent is null or p.intent = p_intent)
  order by p.created_at desc limit 30
$$;

-- Row level security: every table is locked down, then opened only as needed.
alter table profiles enable row level security;
alter table swipes enable row level security;
alter table matches enable row level security;
alter table messages enable row level security;
alter table blocks enable row level security;
alter table reports enable row level security;

create policy "see profiles unless blocked" on profiles for select to authenticated using (
  id = auth.uid() or not exists (
    select 1 from blocks b where (b.blocker = auth.uid() and b.blocked = profiles.id)
                              or (b.blocker = profiles.id and b.blocked = auth.uid()))
);
create policy "create own profile" on profiles for insert to authenticated with check (id = auth.uid());
create policy "edit own profile" on profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "delete own profile" on profiles for delete to authenticated using (id = auth.uid());

create policy "own swipes read" on swipes for select to authenticated using (swiper = auth.uid());
create policy "own swipes write" on swipes for insert to authenticated with check (swiper = auth.uid());

create policy "see own matches" on matches for select to authenticated using (auth.uid() in (user_a, user_b));
create policy "unmatch" on matches for delete to authenticated using (auth.uid() in (user_a, user_b));

create policy "read chat" on messages for select to authenticated using (in_match(match_id));
create policy "send chat" on messages for insert to authenticated with check (sender = auth.uid() and in_match(match_id));

create policy "own blocks" on blocks for all to authenticated using (blocker = auth.uid()) with check (blocker = auth.uid());
create policy "file report" on reports for insert to authenticated with check (reporter = auth.uid());

-- Photos: public to view, but people can only upload into their own folder.
insert into storage.buckets (id, name, public) values ('photos', 'photos', true) on conflict do nothing;
create policy "upload own photo" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "replace own photo" on storage.objects for update to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "delete own photo" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Live chat and instant match alerts.
alter publication supabase_realtime add table messages, matches;
