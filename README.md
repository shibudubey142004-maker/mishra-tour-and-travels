# Mishra Tour and Travels — Phase 7

Customer-facing tour booking website with Supabase.

## Phase 7 additions
- Customer **My Booking History** lookup using the booking phone number + email.
- Previous booking codes, tour, travel date, passengers, vehicle, amount, status and payment status are shown.
- Vehicle selection during booking: **4 Seater, 6 Seater, 14 Seater, 17 Seater**.
- Vehicle capacity is validated during booking.
- Vehicle selection is saved with the booking and shown in the booking confirmation/admin data.

## Supabase migration
Before deploying the updated website, run:

`supabase/phase7_customer_history_vehicle.sql`

in Supabase SQL Editor. This migration is designed for the existing Phase 6 database and adds the required column/functions without requiring a full database reset.

## Deploy
Upload/deploy the updated website files to the existing Vercel project.
