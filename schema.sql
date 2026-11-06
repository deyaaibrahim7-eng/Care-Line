-- =====================================================================
-- Care Line : Supabase schema (PostgreSQL)
-- Run this file once in: Supabase Dashboard > SQL Editor > New query > Run
-- =====================================================================

-- ---------- Tables ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null default 'patient' check (role in ('patient', 'nurse')),
  full_name   text not null,
  birth_date  date,
  phone       text,
  whatsapp    text,
  barriers    text[] not null default '{}',
  created_at  timestamptz not null default now()
);

create table public.medications (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.profiles(id) on delete cascade,
  name        text not null,
  dose        text not null default '',
  slots       text[] not null check (cardinality(slots) > 0 and slots <@ array['m','n','e','b']),
  how         text not null default '',
  why         text not null default '',
  days_left   integer check (days_left is null or days_left >= 0),
  added_at    timestamptz not null default now(),
  stopped_on  date
);

create table public.dose_logs (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.profiles(id) on delete cascade,
  day         date not null,
  slot        text not null check (slot in ('m','n','e','b')),
  status      text not null check (status in ('taken', 'skipped')),
  taken_at    timestamptz not null default now(),
  meds        jsonb not null default '[]'::jsonb,
  unique (patient_id, day, slot)
);

create table public.bp_readings (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.profiles(id) on delete cascade,
  measured_at timestamptz not null default now(),
  sys         smallint not null check (sys between 60 and 260),
  dia         smallint not null check (dia between 30 and 160),
  pulse       smallint check (pulse is null or pulse between 30 and 200)
);

create table public.messages (
  id          uuid primary key default gen_random_uuid(),
  patient_id  uuid not null references public.profiles(id) on delete cascade,
  sender      text not null check (sender in ('patient', 'nurse')),
  sender_id   uuid not null default auth.uid(),
  body        text not null check (char_length(body) between 1 and 2000),
  kind        text not null default 'text' check (kind in ('text', 'call')),
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);

create index medications_patient_idx on public.medications (patient_id);
create index dose_logs_day_idx       on public.dose_logs (day);
create index bp_patient_idx          on public.bp_readings (patient_id, measured_at desc);
create index messages_thread_idx     on public.messages (patient_id, created_at);
create index messages_unread_idx     on public.messages (sender) where read_at is null;

-- ---------- Helper: is the current user a nurse? ----------
create or replace function public.is_nurse()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and role = 'nurse'
  );
$$;

-- ---------- New account -> profile (always created as a patient) ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, birth_date, phone, whatsapp)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
    nullif(new.raw_user_meta_data ->> 'birth_date', '')::date,
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    nullif(new.raw_user_meta_data ->> 'whatsapp', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Mark a conversation as read ----------
create or replace function public.mark_thread_read(p uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() = p then
    update public.messages set read_at = now()
     where patient_id = p and sender = 'nurse' and read_at is null;
  elsif public.is_nurse() then
    update public.messages set read_at = now()
     where patient_id = p and sender = 'patient' and read_at is null;
  end if;
end;
$$;

-- ---------- Row Level Security ----------
alter table public.profiles    enable row level security;
alter table public.medications enable row level security;
alter table public.dose_logs   enable row level security;
alter table public.bp_readings enable row level security;
alter table public.messages    enable row level security;

-- profiles: a patient sees only their own row, a nurse sees everyone
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_nurse());
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- medications: patient manages their own, nurse can read all (no hard delete: history is kept)
create policy meds_select on public.medications for select to authenticated
  using (patient_id = (select auth.uid()) or public.is_nurse());
create policy meds_insert on public.medications for insert to authenticated
  with check (patient_id = (select auth.uid()));
create policy meds_update on public.medications for update to authenticated
  using (patient_id = (select auth.uid())) with check (patient_id = (select auth.uid()));

-- dose logs
create policy logs_select on public.dose_logs for select to authenticated
  using (patient_id = (select auth.uid()) or public.is_nurse());
create policy logs_insert on public.dose_logs for insert to authenticated
  with check (patient_id = (select auth.uid()));
create policy logs_update on public.dose_logs for update to authenticated
  using (patient_id = (select auth.uid())) with check (patient_id = (select auth.uid()));

-- blood pressure readings
create policy bp_select on public.bp_readings for select to authenticated
  using (patient_id = (select auth.uid()) or public.is_nurse());
create policy bp_insert on public.bp_readings for insert to authenticated
  with check (patient_id = (select auth.uid()));
create policy bp_delete on public.bp_readings for delete to authenticated
  using (patient_id = (select auth.uid()));

-- messages: both sides read the thread; each side can only write as itself
create policy msgs_select on public.messages for select to authenticated
  using (patient_id = (select auth.uid()) or public.is_nurse());
create policy msgs_insert on public.messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and (
      (sender = 'patient' and patient_id = (select auth.uid()))
      or (sender = 'nurse' and public.is_nurse())
    )
  );

-- ---------- Nurse resets a patient's password (forgot-password flow) ----------
create or replace function public.nurse_set_password(p uuid, new_password text)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
begin
  if not public.is_nurse() then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(coalesce(new_password, '')) < 6 then raise exception 'password too short' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = p and role = 'patient') then raise exception 'not a patient' using errcode = '22023'; end if;
  update auth.users set encrypted_password = crypt(new_password, gen_salt('bf')), updated_at = now() where id = p;
end $$;
revoke execute on function public.nurse_set_password(uuid, text) from public, anon;
grant execute on function public.nurse_set_password(uuid, text) to authenticated;

-- ---------- Privileges ----------
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;

-- a user may change only these profile columns (never "role")
revoke update on public.profiles from authenticated;
grant update (full_name, birth_date, phone, whatsapp, barriers) on public.profiles to authenticated;

revoke execute on function public.mark_thread_read(uuid) from public, anon;
grant  execute on function public.mark_thread_read(uuid) to authenticated;
revoke execute on function public.is_nurse() from public, anon;
grant  execute on function public.is_nurse() to authenticated;

-- =====================================================================
-- AFTER the first nurse account is created in
-- Authentication > Users > Add user (email + password, "Auto Confirm User" on),
-- run this (replace the email), then she/he can sign in to the Dashboard:
--
--   update public.profiles
--      set role = 'nurse', full_name = 'Nurse Name'
--    where id = (select id from auth.users where email = 'nurse@example.com');
-- =====================================================================
