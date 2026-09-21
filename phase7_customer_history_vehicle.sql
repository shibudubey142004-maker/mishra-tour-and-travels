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
