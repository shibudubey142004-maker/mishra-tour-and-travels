-- Mishra Tour and Travels — Supabase production schema
create extension if not exists pgcrypto;

create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  destination text not null,
  vehicle text not null,
  duration_days int not null default 1 check(duration_days > 0),
  price numeric(12,2) not null check(price >= 0),
  total_seats int not null check(total_seats > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.ride_availability (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides(id) on delete cascade,
  travel_date date not null,
  blocked boolean not null default false,
  available_seats int not null check(available_seats >= 0),
  unique(ride_id, travel_date)
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text not null,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_code text unique not null,
  ride_id uuid not null references public.rides(id),
  customer_id uuid not null references public.customers(id),
  travel_date date not null,
  passengers int not null check(passengers > 0),
  pickup text not null,
  amount numeric(12,2) not null default 0,
  status text not null default 'confirmed' check(status in ('pending','confirmed','cancelled','completed')),
  payment_status text not null default 'pending' check(payment_status in ('pending','paid','failed','refunded')),
  created_at timestamptz not null default now()
);

create index if not exists bookings_date_idx on public.bookings(travel_date);
create index if not exists bookings_ride_date_idx on public.bookings(ride_id, travel_date);

-- Seed rides
insert into public.rides(title,destination,vehicle,duration_days,price,total_seats)
select * from (values
('Agra Heritage Day Tour','Agra','Toyota Innova',1,4999::numeric,6),
('Jaipur Royal City Ride','Jaipur','Tempo Traveller',2,8999::numeric,12),
('Delhi City Explorer','Delhi','Sedan',1,3499::numeric,4),
('Manali Mountain Escape','Manali','SUV',3,12999::numeric,6),
('Goa Coastal Getaway','Goa','Tempo Traveller',3,14999::numeric,12)
) v(title,destination,vehicle,duration_days,price,total_seats)
where not exists (select 1 from public.rides r where r.title=v.title);

-- Customer-facing read access
alter table public.rides enable row level security;
alter table public.ride_availability enable row level security;
alter table public.customers enable row level security;
alter table public.bookings enable row level security;

drop policy if exists "public read active rides" on public.rides;
create policy "public read active rides" on public.rides
for select to anon, authenticated using (active = true);

drop policy if exists "public read availability" on public.ride_availability;
create policy "public read availability" on public.ride_availability
for select to anon, authenticated using (blocked = false);

-- No direct public insert/update/delete policies on customers/bookings.
-- Bookings are created through the RPC below so seats can be checked atomically.

create or replace function public.create_public_booking(
  p_ride_id uuid,
  p_travel_date date,
  p_passengers int,
  p_name text,
  p_phone text,
  p_email text,
  p_pickup text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride public.rides%rowtype;
  v_avail public.ride_availability%rowtype;
  v_customer_id uuid;
  v_booking_code text;
  v_booking_id uuid;
  v_amount numeric(12,2);
begin
  if p_passengers <= 0 then raise exception 'Passenger count must be greater than zero'; end if;
  if p_travel_date < current_date then raise exception 'Travel date cannot be in the past'; end if;

  select * into v_ride from public.rides where id=p_ride_id and active=true for share;
  if not found then raise exception 'Tour is not available'; end if;

  insert into public.ride_availability(ride_id, travel_date, blocked, available_seats)
  values(p_ride_id, p_travel_date, false, v_ride.total_seats)
  on conflict (ride_id, travel_date) do nothing;

  select * into v_avail
  from public.ride_availability
  where ride_id=p_ride_id and travel_date=p_travel_date
  for update;

  if v_avail.blocked then raise exception 'This date is blocked'; end if;
  if v_avail.available_seats < p_passengers then
    raise exception 'Only % seat(s) are available', v_avail.available_seats;
  end if;

  insert into public.customers(name,phone,email)
  values(trim(p_name),trim(p_phone),nullif(trim(p_email),''))
  returning id into v_customer_id;

  v_booking_code := 'MTT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  v_amount := v_ride.price * p_passengers;

  insert into public.bookings(
    booking_code,ride_id,customer_id,travel_date,passengers,pickup,amount
  ) values(
    v_booking_code,p_ride_id,v_customer_id,p_travel_date,p_passengers,trim(p_pickup),v_amount
  ) returning id into v_booking_id;

  update public.ride_availability
  set available_seats=available_seats-p_passengers
  where id=v_avail.id;

  return json_build_object(
    'booking_id',v_booking_id,
    'booking_code',v_booking_code,
    'amount',v_amount,
    'remaining_seats',v_avail.available_seats-p_passengers
  );
end;
$$;

revoke all on function public.create_public_booking(uuid,date,int,text,text,text,text) from public;
grant execute on function public.create_public_booking(uuid,date,int,text,text,text,text) to anon, authenticated;

-- Public users need execute access to the function only.
-- Admin dashboard should use Supabase Auth + authenticated RLS policies
-- (or a server/Edge Function with a secret key) before production deployment.

-- ============================================================
-- ADMIN DASHBOARD / AUTHENTICATED ADMIN ACCESS
-- Run this section after the base schema.
-- 1) Create the admin user in Supabase Dashboard > Authentication > Users.
-- 2) Replace the email below with that exact admin email and run this SQL.
-- ============================================================
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

drop policy if exists "admins can read own admin row" on public.admin_users;
create policy "admins can read own admin row" on public.admin_users
for select to authenticated using (user_id = auth.uid());

-- Replace this email before running.
-- insert into public.admin_users(user_id)
-- select id from auth.users where email = 'YOUR_ADMIN_EMAIL@example.com'
-- on conflict do nothing;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(select 1 from public.admin_users where user_id = auth.uid());
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Admin CRUD policies. Public customers keep the restricted policies above.
drop policy if exists "admin read rides" on public.rides;
drop policy if exists "admin insert rides" on public.rides;
drop policy if exists "admin update rides" on public.rides;
drop policy if exists "admin delete rides" on public.rides;
create policy "admin read rides" on public.rides for select to authenticated using (public.is_admin());
create policy "admin insert rides" on public.rides for insert to authenticated with check (public.is_admin());
create policy "admin update rides" on public.rides for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin delete rides" on public.rides for delete to authenticated using (public.is_admin());

drop policy if exists "admin read availability" on public.ride_availability;
drop policy if exists "admin insert availability" on public.ride_availability;
drop policy if exists "admin update availability" on public.ride_availability;
drop policy if exists "admin delete availability" on public.ride_availability;
create policy "admin read availability" on public.ride_availability for select to authenticated using (public.is_admin());
create policy "admin insert availability" on public.ride_availability for insert to authenticated with check (public.is_admin());
create policy "admin update availability" on public.ride_availability for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin delete availability" on public.ride_availability for delete to authenticated using (public.is_admin());

drop policy if exists "admin read customers" on public.customers;
create policy "admin read customers" on public.customers for select to authenticated using (public.is_admin());

drop policy if exists "admin read bookings" on public.bookings;
create policy "admin read bookings" on public.bookings for select to authenticated using (public.is_admin());

-- Change booking status safely. Cancelling restores seats; re-confirming a cancelled
-- booking consumes them again. Other status changes do not alter availability.
create or replace function public.admin_update_booking_status(
  p_booking_id uuid,
  p_status text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_avail public.ride_availability%rowtype;
  v_old_status text;
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  if p_status not in ('pending','confirmed','cancelled','completed') then raise exception 'Invalid booking status'; end if;

  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  v_old_status := v_booking.status;

  if v_old_status = p_status then
    return json_build_object('booking_id',p_booking_id,'status',p_status);
  end if;

  if v_old_status <> 'cancelled' and p_status = 'cancelled' then
    select * into v_avail from public.ride_availability
    where ride_id=v_booking.ride_id and travel_date=v_booking.travel_date for update;
    if found then
      update public.ride_availability set available_seats=available_seats+v_booking.passengers where id=v_avail.id;
    end if;
  elsif v_old_status = 'cancelled' and p_status <> 'cancelled' then
    select * into v_avail from public.ride_availability
    where ride_id=v_booking.ride_id and travel_date=v_booking.travel_date for update;
    if not found then
      raise exception 'Availability record not found';
    end if;
    if v_avail.blocked or v_avail.available_seats < v_booking.passengers then
      raise exception 'Not enough seats to reactivate this booking';
    end if;
    update public.ride_availability set available_seats=available_seats-v_booking.passengers where id=v_avail.id;
  end if;

  update public.bookings set status=p_status where id=p_booking_id;
  return json_build_object('booking_id',p_booking_id,'status',p_status);
end;
$$;

create or replace function public.admin_update_payment_status(
  p_booking_id uuid,
  p_payment_status text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Not authorized'; end if;
  if p_payment_status not in ('pending','paid','failed','refunded') then raise exception 'Invalid payment status'; end if;
  update public.bookings set payment_status=p_payment_status where id=p_booking_id;
  if not found then raise exception 'Booking not found'; end if;
  return json_build_object('booking_id',p_booking_id,'payment_status',p_payment_status);
end;
$$;

revoke all on function public.admin_update_booking_status(uuid,text) from public;
grant execute on function public.admin_update_booking_status(uuid,text) to authenticated;
revoke all on function public.admin_update_payment_status(uuid,text) from public;
grant execute on function public.admin_update_payment_status(uuid,text) to authenticated;

-- ============================================================
-- TOUR + AVAILABILITY MANAGEMENT
-- The admin dashboard uses the authenticated RLS policies above
-- to create/update/deactivate tours and manage travel-date rows.
-- ============================================================
-- Keep bookings safe: rides should normally be deactivated rather
-- than deleted because existing bookings reference the ride.
-- Mishra Tour and Travels — Phase 7 migration
-- Adds customer booking history + selectable vehicle type.
-- Run this ONCE in Supabase SQL Editor before deploying the updated website.

alter table public.bookings
  add column if not exists vehicle_type text;

update public.bookings
set vehicle_type = coalesce(vehicle_type, 'Existing vehicle')
where vehicle_type is null;

-- Replace the old public booking function with the new signature.
drop function if exists public.create_public_booking(uuid,date,int,text,text,text,text);
drop function if exists public.create_public_booking(uuid,date,int,text,text,text,text,text);

create or replace function public.create_public_booking(
  p_ride_id uuid,
  p_travel_date date,
  p_passengers int,
  p_name text,
  p_phone text,
  p_email text,
  p_pickup text,
  p_vehicle_type text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride public.rides%rowtype;
  v_avail public.ride_availability%rowtype;
  v_customer_id uuid;
  v_booking_code text;
  v_booking_id uuid;
  v_amount numeric(12,2);
  v_vehicle_capacity int;
begin
  if p_passengers <= 0 then raise exception 'Passenger count must be greater than zero'; end if;
  if p_travel_date < current_date then raise exception 'Travel date cannot be in the past'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Name is required'; end if;
  if nullif(trim(p_phone),'') is null then raise exception 'Phone is required'; end if;
  if nullif(trim(p_email),'') is null then raise exception 'Email is required'; end if;
  if p_vehicle_type not in ('4 Seater','6 Seater','14 Seater','17 Seater') then
    raise exception 'Please select a valid vehicle';
  end if;

  v_vehicle_capacity := case p_vehicle_type
    when '4 Seater' then 4
    when '6 Seater' then 6
    when '14 Seater' then 14
    when '17 Seater' then 17
  end;

  if p_passengers > v_vehicle_capacity then
    raise exception '% can carry a maximum of % passengers', p_vehicle_type, v_vehicle_capacity;
  end if;

  select * into v_ride from public.rides where id=p_ride_id and active=true for share;
  if not found then raise exception 'Tour is not available'; end if;

  insert into public.ride_availability(ride_id, travel_date, blocked, available_seats)
  values(p_ride_id, p_travel_date, false, v_ride.total_seats)
  on conflict (ride_id, travel_date) do nothing;

  select * into v_avail
  from public.ride_availability
  where ride_id=p_ride_id and travel_date=p_travel_date
  for update;

  if v_avail.blocked then raise exception 'This date is blocked'; end if;
  if v_avail.available_seats < p_passengers then
    raise exception 'Only % seat(s) are available', v_avail.available_seats;
  end if;

  insert into public.customers(name,phone,email)
  values(trim(p_name),trim(p_phone),lower(trim(p_email)))
  returning id into v_customer_id;

  v_booking_code := 'MTT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  v_amount := v_ride.price * p_passengers;

  insert into public.bookings(
    booking_code,ride_id,customer_id,travel_date,passengers,pickup,amount,vehicle_type
  ) values(
    v_booking_code,p_ride_id,v_customer_id,p_travel_date,p_passengers,trim(p_pickup),v_amount,p_vehicle_type
  ) returning id into v_booking_id;

  update public.ride_availability
  set available_seats=available_seats-p_passengers
  where id=v_avail.id;

  return json_build_object(
    'booking_id',v_booking_id,
    'booking_code',v_booking_code,
    'amount',v_amount,
    'vehicle_type',p_vehicle_type,
    'remaining_seats',v_avail.available_seats-p_passengers
  );
end;
$$;

revoke all on function public.create_public_booking(uuid,date,int,text,text,text,text,text) from public;
grant execute on function public.create_public_booking(uuid,date,int,text,text,text,text,text) to anon, authenticated;

-- Customer history lookup.
-- Requires BOTH phone and email so a random visitor cannot retrieve a customer's
-- bookings using only a phone number.
create or replace function public.get_public_booking_history(
  p_phone text,
  p_email text
)
returns table(
  booking_code text,
  title text,
  destination text,
  travel_date date,
  passengers int,
  pickup text,
  amount numeric,
  status text,
  payment_status text,
  vehicle_type text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if nullif(trim(p_phone),'') is null then raise exception 'Phone is required'; end if;
  if nullif(trim(p_email),'') is null then raise exception 'Email is required'; end if;

  return query
  select
    b.booking_code,
    r.title,
    r.destination,
    b.travel_date,
    b.passengers,
    b.pickup,
    b.amount,
    b.status,
    b.payment_status,
    coalesce(b.vehicle_type, r.vehicle, 'Not specified') as vehicle_type,
    b.created_at
  from public.bookings b
  join public.customers c on c.id=b.customer_id
  join public.rides r on r.id=b.ride_id
  where regexp_replace(c.phone, '\D', '', 'g') = regexp_replace(trim(p_phone), '\D', '', 'g')
    and lower(trim(coalesce(c.email,''))) = lower(trim(p_email))
  order by b.created_at desc;
end;
$$;

revoke all on function public.get_public_booking_history(text,text) from public;
grant execute on function public.get_public_booking_history(text,text) to anon, authenticated;
