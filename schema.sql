-- ============================================================
-- Blind-Date-Studie: Datenbank-Schema (Supabase / Postgres)
-- Einmal komplett im Supabase "SQL Editor" ausführen.
-- ============================================================

-- ---------- Tabellen ----------
create table admins (email text primary key);            -- Noemi, Lea (+ du)

create table slots (                                     -- feste Termine
  id bigserial primary key,
  starts_at timestamptz not null,
  label text,                                            -- z. B. "Labor 1"
  capacity int not null default 1                        -- wie viele Dates gleichzeitig möglich
);

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  codename text unique not null,
  age int not null check (age between 18 and 28),
  gender text not null check (gender in ('w','m','d')),
  seeking text[] not null,                               -- gesuchte Geschlechter
  hobbies text,
  consent_at timestamptz not null,                       -- Zeitpunkt der Datenschutz-Zustimmung
  locked boolean not null default false,                 -- true = hat ein Match, kann nicht mehr swipen
  cancel_count int not null default 0,
  created_at timestamptz not null default now()
);

create table availabilities (
  user_id uuid references profiles on delete cascade,
  slot_id bigint references slots on delete cascade,
  primary key (user_id, slot_id)
);

create table likes (
  from_id uuid references profiles on delete cascade,
  to_id uuid references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_id, to_id)
);

create table matches (
  id bigserial primary key,
  a_id uuid not null references profiles,
  b_id uuid not null references profiles,
  slot_id bigint not null references slots,
  status text not null default 'pending' check (status in ('pending','confirmed','cancelled')),
  a_confirmed boolean not null default false,
  b_confirmed boolean not null default false,
  condition text,                                        -- z. B. 'face-to-face' / 'wand' (Noemi trägt ein)
  cancelled_by uuid references profiles,
  created_at timestamptz not null default now()
);

create table messages (                                  -- Nachrichten an das Studienteam
  id bigserial primary key,
  user_id uuid not null references profiles on delete cascade default auth.uid(),
  body text not null,
  created_at timestamptz not null default now()
);

-- ---------- Zugriffsschutz (Row Level Security) ----------
alter table admins enable row level security;
alter table slots enable row level security;
alter table profiles enable row level security;
alter table availabilities enable row level security;
alter table likes enable row level security;
alter table matches enable row level security;
alter table messages enable row level security;

create policy "slots lesen" on slots for select to authenticated using (true);
create policy "eigenes profil" on profiles for select to authenticated using (id = auth.uid());
create policy "eigene verfuegbarkeit" on availabilities for select to authenticated using (user_id = auth.uid());
create policy "eigene nachrichten lesen" on messages for select to authenticated using (user_id = auth.uid());
create policy "nachricht senden" on messages for insert to authenticated with check (user_id = auth.uid());
-- Alles andere läuft ausschließlich über die Funktionen unten.

-- ---------- Hilfsfunktionen ----------
create or replace function is_admin() returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(auth.jwt() ->> 'email'))
$$;

-- Erster passender Termin, der für beide frei ist (Kapazität + mind. 12 h Vorlauf)
create or replace function free_slot(a uuid, b uuid) returns bigint
language sql security definer set search_path = public as $$
  select s.id from slots s
  join availabilities x on x.slot_id = s.id and x.user_id = a
  join availabilities y on y.slot_id = s.id and y.user_id = b
  where s.starts_at > now() + interval '12 hours'
    and (select count(*) from matches m where m.slot_id = s.id and m.status <> 'cancelled') < s.capacity
  order by s.starts_at limit 1
$$;

-- ---------- Registrierung ----------
create or replace function register_profile(p_age int, p_gender text, p_seeking text[], p_hobbies text, p_slots bigint[])
returns text language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  adj text[] := array['Blauer','Roter','Gruener','Stiller','Flinker','Sanfter','Wilder','Kluger'];
  ani text[] := array['Fuchs','Otter','Falke','Luchs','Igel','Rabe','Biber','Dachs'];
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if exists (select 1 from profiles where id = auth.uid()) then raise exception 'Profil existiert bereits'; end if;
  if coalesce(array_length(p_slots, 1), 0) < 1 then raise exception 'Bitte mindestens einen Termin wählen'; end if;
  loop
    v_code := adj[1 + floor(random()*8)::int] || ani[1 + floor(random()*8)::int] || '-' || (10 + floor(random()*90))::int;
    exit when not exists (select 1 from profiles where codename = v_code);
  end loop;
  insert into profiles (id, codename, age, gender, seeking, hobbies, consent_at)
  values (auth.uid(), v_code, p_age, p_gender, p_seeking, left(p_hobbies, 300), now());
  insert into availabilities (user_id, slot_id)
  select auth.uid(), s.id from slots s where s.id = any (p_slots);
  return v_code;
end $$;

-- ---------- Swipen ----------
-- Zeigt nur Personen, die gegenseitig passen (Geschlecht/Suchpräferenz), nicht gesperrt sind
-- und mit denen es mindestens einen freien gemeinsamen Termin gibt.
create or replace function get_candidates()
returns table (codename text, age int, gender text, hobbies text)
language sql security definer set search_path = public as $$
  select p.codename, p.age, p.gender, p.hobbies
  from profiles me, profiles p
  where me.id = auth.uid() and not me.locked
    and p.id <> me.id and not p.locked
    and me.gender = any (p.seeking) and p.gender = any (me.seeking)
    and not exists (select 1 from likes l where l.from_id = me.id and l.to_id = p.id)
    and free_slot(me.id, p.id) is not null
  order by random()
$$;

create or replace function like_profile(p_codename text) returns json
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid(); t uuid; v_slot bigint;
begin
  select id into t from profiles where codename = p_codename;
  if t is null or t = me then raise exception 'Unbekanntes Profil'; end if;

  -- Beide Personen sperren, damit parallele Likes keine Doppel-Matches erzeugen
  perform 1 from profiles where id in (me, t) order by id for update;
  if exists (select 1 from profiles where id in (me, t) and locked) then
    return json_build_object('matched', false, 'reason', 'locked');
  end if;
  if not exists (select 1 from profiles a, profiles b
                 where a.id = me and b.id = t
                   and a.gender = any (b.seeking) and b.gender = any (a.seeking)) then
    raise exception 'Profil nicht kompatibel';
  end if;

  insert into likes (from_id, to_id) values (me, t) on conflict do nothing;

  if exists (select 1 from likes where from_id = t and to_id = me) then
    v_slot := free_slot(me, t);
    if v_slot is not null then
      perform 1 from slots where id = v_slot for update;   -- Kapazität absichern
      v_slot := free_slot(me, t);
      if v_slot is not null then
        insert into matches (a_id, b_id, slot_id) values (me, t, v_slot);
        update profiles set locked = true where id in (me, t);
        return json_build_object('matched', true);
      end if;
    end if;
  end if;
  return json_build_object('matched', false);
end $$;

-- ---------- Mein Match / Bestätigen / Absagen ----------
create or replace function my_match()
returns table (match_id bigint, partner_codename text, partner_age int, partner_hobbies text,
               starts_at timestamptz, slot_label text, status text, i_confirmed boolean)
language sql security definer set search_path = public as $$
  select m.id, p.codename, p.age, p.hobbies, s.starts_at, s.label, m.status,
         case when m.a_id = auth.uid() then m.a_confirmed else m.b_confirmed end
  from matches m
  join slots s on s.id = m.slot_id
  join profiles p on p.id = case when m.a_id = auth.uid() then m.b_id else m.a_id end
  where m.status <> 'cancelled' and (m.a_id = auth.uid() or m.b_id = auth.uid())
$$;

create or replace function confirm_match() returns void
language plpgsql security definer set search_path = public as $$
begin
  update matches set a_confirmed = a_confirmed or a_id = auth.uid(),
                     b_confirmed = b_confirmed or b_id = auth.uid()
  where status <> 'cancelled' and (a_id = auth.uid() or b_id = auth.uid());
  update matches set status = 'confirmed' where status = 'pending' and a_confirmed and b_confirmed;
end $$;

-- Absage: Termin wird frei, beide Personen können wieder swipen,
-- das gegenseitige Like der beiden wird gelöscht (kein erneutes Match derselben Personen).
create or replace function cancel_match() returns void
language plpgsql security definer set search_path = public as $$
declare m matches%rowtype;
begin
  select * into m from matches where status <> 'cancelled' and (a_id = auth.uid() or b_id = auth.uid());
  if not found then raise exception 'Kein aktiver Termin'; end if;
  update matches set status = 'cancelled', cancelled_by = auth.uid() where id = m.id;
  update profiles set locked = false where id in (m.a_id, m.b_id);
  update profiles set cancel_count = cancel_count + 1 where id = auth.uid();
  delete from likes where (from_id = m.a_id and to_id = m.b_id) or (from_id = m.b_id and to_id = m.a_id);
end $$;

-- ---------- Admin-Auswertung (liefert nur Daten, wenn die E-Mail in "admins" steht) ----------
create or replace function admin_profiles()
returns table (codename text, email text, alter_jahre int, geschlecht text, sucht text, hobbys text,
               hat_match boolean, absagen int, registriert timestamptz)
language sql security definer set search_path = public as $$
  select p.codename, u.email::text, p.age, p.gender, array_to_string(p.seeking, ','), p.hobbies,
         p.locked, p.cancel_count, p.created_at
  from profiles p join auth.users u on u.id = p.id
  where is_admin() order by p.created_at
$$;

create or replace function admin_matches()
returns table (match_id bigint, termin timestamptz, raum text, status text,
               person_a text, email_a text, a_bestaetigt boolean,
               person_b text, email_b text, b_bestaetigt boolean, bedingung text)
language sql security definer set search_path = public as $$
  select m.id, s.starts_at, s.label, m.status,
         pa.codename, ua.email::text, m.a_confirmed,
         pb.codename, ub.email::text, m.b_confirmed, m.condition
  from matches m
  join slots s on s.id = m.slot_id
  join profiles pa on pa.id = m.a_id join auth.users ua on ua.id = pa.id
  join profiles pb on pb.id = m.b_id join auth.users ub on ub.id = pb.id
  where is_admin() order by s.starts_at
$$;

-- ---------- Danach manuell ausfüllen (Beispiele) ----------
-- insert into admins values ('noemi@...'), ('lea@...'), ('deine@mail.at');
-- insert into slots (starts_at, label, capacity) values ('2026-12-01 14:00+01', 'Labor 1', 2);
