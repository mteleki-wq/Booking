-- ============================================================
-- BOOKING BACKEND — MULTI-TENANT MIGRATION
-- One Supabase project serving every restaurant.
--
-- WHAT THIS CHANGES
--   Before: one set of tables = one restaurant. A second client
--           needed a second Supabase project (and a second bill).
--   After:  a venues table, and every booking tagged with venue_id.
--           One project, any number of restaurants, fully isolated.
--
-- BEFORE YOU RUN IT --------------------------------------------
-- This was written against the standard booking schema
--   (bookings, booking_settings, get_availability, create_booking).
-- Confirm yours matches by running this first in the SQL Editor:
--
--   select table_name, column_name, data_type
--     from information_schema.columns
--    where table_schema='public'
--      and table_name in ('bookings','booking_settings')
--    order by table_name, ordinal_position;
--
--   select p.proname, pg_get_function_identity_arguments(p.oid) as args
--     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--    where n.nspname='public' and p.proname in ('create_booking','get_availability');
--
-- If any column name differs, adjust this file before running.
-- TAKE A BACKUP FIRST (Database -> Backups, or export bookings to CSV).
--
-- IMPORTANT: after this runs, the OLD single-tenant create_booking
-- (the one without a venue argument) will fail, because bookings.venue_id
-- is now NOT NULL. That is deliberate — it fails safely instead of
-- writing orphaned rows. Update the website's RPC calls in the same
-- session, then drop the old function signatures.
--
-- Safe to run more than once.
-- ============================================================


-- ---------- 1. venues ----------
create table if not exists venues (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,          -- public identifier, e.g. 'cafe-bojo'
  name        text not null,
  timezone    text not null default 'Australia/Sydney',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- 2. who can see which venue ----------
create table if not exists venue_staff (
  venue_id  uuid not null references venues(id) on delete cascade,
  user_id   uuid not null,
  role      text not null default 'staff',
  primary key (venue_id, user_id)
);

-- ---------- 3. add venue_id to existing tables ----------
alter table bookings         add column if not exists venue_id uuid references venues(id) on delete cascade;
alter table bookings         add column if not exists slot_id  text;  -- 's1' / 's2', matches the site's slot ids
update bookings set slot_id = coalesce(slot_id, 's1') where slot_id is null;
alter table booking_settings add column if not exists venue_id uuid references venues(id) on delete cascade;
-- rule columns are optional in older installs; add them only if missing
alter table booking_settings add column if not exists max_guests_per_booking int not null default 12;
alter table booking_settings add column if not exists open_days int not null default 60;

-- ---------- 4. move existing data onto a first venue ----------
insert into venues (slug, name)
select 'maison-escapade', 'Maison Escapade'
where not exists (select 1 from venues where slug = 'maison-escapade');

update bookings
   set venue_id = (select id from venues where slug = 'maison-escapade')
 where venue_id is null;

update booking_settings
   set venue_id = (select id from venues where slug = 'maison-escapade')
 where venue_id is null;

-- settings are now one row per venue, not a single global row.
-- the old id column defaulted to 1 for the single global row — give it a
-- real sequence so additional venues can be inserted.
alter table booking_settings drop constraint if exists booking_settings_pkey;
create sequence if not exists booking_settings_id_seq owned by booking_settings.id;
select setval('booking_settings_id_seq',
              coalesce((select max(id) from booking_settings), 0) + 1, false);
alter table booking_settings alter column id set default nextval('booking_settings_id_seq');
do $$ begin
  alter table booking_settings add constraint booking_settings_pkey primary key (id);
exception when duplicate_table then null; when duplicate_object then null; end $$;
do $$ begin
  alter table booking_settings add constraint booking_settings_venue_key unique (venue_id);
exception when duplicate_table then null; when duplicate_object then null; end $$;

alter table bookings         alter column venue_id set not null;
alter table booking_settings alter column venue_id set not null;

create index if not exists bookings_venue_date_idx on bookings (venue_id, booking_date);

-- ---------- 5. row level security ----------
alter table venues           enable row level security;
alter table venue_staff      enable row level security;
alter table bookings         enable row level security;
alter table booking_settings enable row level security;

-- helper: the venues the signed-in staff member belongs to
create or replace function public.my_venue_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select venue_id from venue_staff where user_id = auth.uid()
$$;

-- bookings: staff see only their own venue. anon gets NOTHING directly.
drop policy if exists bookings_staff_all on bookings;
create policy bookings_staff_all on bookings
  for all to authenticated
  using      (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids()));

drop policy if exists settings_staff_read on booking_settings;
create policy settings_staff_read on booking_settings
  for select to authenticated
  using (venue_id in (select public.my_venue_ids()));

drop policy if exists settings_staff_write on booking_settings;
create policy settings_staff_write on booking_settings
  for update to authenticated
  using      (venue_id in (select public.my_venue_ids()))
  with check (venue_id in (select public.my_venue_ids()));

drop policy if exists venues_staff_read on venues;
create policy venues_staff_read on venues
  for select to authenticated
  using (id in (select public.my_venue_ids()));

drop policy if exists venue_staff_self on venue_staff;
create policy venue_staff_self on venue_staff
  for select to authenticated
  using (user_id = auth.uid());

-- Supabase grants these by default; stated explicitly so the file is self-contained
grant usage on schema public to anon, authenticated;

-- no table privileges for the public key at all
revoke all on bookings, booking_settings, venues, venue_staff from anon;
grant  select, insert, update, delete on bookings         to authenticated;
grant  select, update                 on booking_settings to authenticated;
grant  select                         on venues, venue_staff to authenticated;

-- ---------- 6. public RPCs (the only thing the anon key may call) ----------
-- These keep the SAME argument names and return shape as the original
-- single-restaurant functions, with one added first argument: p_venue.
-- The booking page therefore only needs that one extra field.

-- seats already taken today, keyed by slot id: {"online_seats":60,"taken":{"s1":52}}
create or replace function public.get_availability(p_venue text, p_date date)
returns json
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_seats int; v_total int; v_taken json;
begin
  select id into v_id from venues where slug = p_venue and active;
  if v_id is null then raise exception 'unknown venue'; end if;

  select online_seats into v_seats from booking_settings where venue_id = v_id;
  v_seats := coalesce(v_seats, 60);

  select coalesce(json_object_agg(t.slot_id, t.n), '{}'::json) into v_taken
    from (
      select slot_id, sum(guests)::int as n
        from bookings
       where venue_id = v_id and booking_date = p_date and status <> 'cancelled'
       group by slot_id
    ) t;

  select total_capacity into v_total from booking_settings where venue_id = v_id;
  return json_build_object('online_seats', v_seats, 'total_capacity', coalesce(v_total, v_seats),
                           'date', p_date, 'taken', v_taken);
end $$;

-- create a booking, checking capacity inside the same lock
create or replace function public.create_booking(
  p_venue text, p_date date, p_slot_id text, p_slot_label text, p_arrival text,
  p_guests int, p_name text, p_phone text, p_email text, p_notes text
) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  v_id uuid; v_seats int; v_max int; v_open int; v_taken int; v_ref text;
begin
  select id into v_id from venues where slug = p_venue and active;
  if v_id is null then
    return json_build_object('ok', false, 'message', 'Unknown venue.');
  end if;

  if p_guests is null or p_guests < 1 then
    return json_build_object('ok', false, 'message', 'Please choose how many guests.');
  end if;
  if p_name is null or btrim(p_name) = '' or p_email is null or btrim(p_email) = '' then
    return json_build_object('ok', false, 'message', 'Name and email are required.');
  end if;
  if p_slot_id is null or btrim(p_slot_id) = '' then
    return json_build_object('ok', false, 'message', 'Please choose a sitting.');
  end if;

  select online_seats, max_guests_per_booking, open_days
    into v_seats, v_max, v_open
    from booking_settings where venue_id = v_id;
  v_seats := coalesce(v_seats, 60);
  v_max   := coalesce(v_max, 10);
  v_open  := coalesce(v_open, 90);

  if p_guests > v_max then
    return json_build_object('ok', false, 'message',
      'For parties over ' || v_max || ' please call us directly.');
  end if;
  if p_date < current_date or p_date > current_date + v_open then
    return json_build_object('ok', false, 'message', 'That date is outside our booking window.');
  end if;

  -- serialise everyone booking this venue+date+sitting, so two people
  -- cannot take the last table at the same moment
  perform pg_advisory_xact_lock(hashtext(v_id::text || p_date::text || p_slot_id));

  select coalesce(sum(guests), 0) into v_taken
    from bookings
   where venue_id = v_id and booking_date = p_date
     and slot_id = p_slot_id and status <> 'cancelled';

  if v_taken + p_guests > v_seats then
    return json_build_object('ok', false,
      'message', 'That sitting is fully booked.',
      'seats_left', greatest(0, v_seats - v_taken));
  end if;

  v_ref := upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));

  insert into bookings (venue_id, booking_date, slot_id, slot_label, arrival_time,
                        name, email, phone, guests, notes, ref)
  values (v_id, p_date, p_slot_id, p_slot_label, p_arrival,
          btrim(p_name), btrim(p_email), p_phone, p_guests, p_notes, v_ref);

  return json_build_object('ok', true, 'ref', v_ref, 'message', 'Booking confirmed.');
end $$;

revoke all on function public.get_availability(text, date) from public;
revoke all on function public.create_booking(text, date, text, text, text, int, text, text, text, text) from public;
grant execute on function public.get_availability(text, date) to anon, authenticated;
grant execute on function public.create_booking(text, date, text, text, text, int, text, text, text, text) to anon, authenticated;

-- ---------- 7. adding a new restaurant ----------
create or replace function public.add_venue(
  p_slug text, p_name text, p_online_seats int default 60, p_total_capacity int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into venues (slug, name) values (p_slug, p_name) returning id into v_id;
  insert into booking_settings (venue_id, online_seats, total_capacity)
  values (v_id, p_online_seats, coalesce(p_total_capacity, p_online_seats));
  return v_id;
end $$;
revoke all on function public.add_venue(text, text, int, int) from public, anon;
