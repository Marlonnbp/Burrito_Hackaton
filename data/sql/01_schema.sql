-- =============================================================
-- Burrito Tracker UNMSM — 01_schema.sql
-- Ejecutar en Supabase > SQL Editor (antes de 02_seed_stops.sql)
-- Circuito 1D: loop L = 2677.29 m (ver data/route_data.json y CLAUDE.md)
-- =============================================================

create extension if not exists "pgcrypto";

-- ---------- stops ----------
create table if not exists public.stops (
  id           serial primary key,
  name         text not null unique,
  lat          double precision not null,
  lng          double precision not null,
  distance_m   double precision not null check (distance_m >= 0),
  order_index  integer not null unique
);

-- ---------- reports ----------
create table if not exists public.reports (
  uuid             uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  user_id          text not null,
  report_type      text not null default 'bus_here',   -- bus_here | on_board | bus_passed
  lat              double precision not null,
  lng              double precision not null,
  distance_m       double precision,                   -- proyección 1D (la llena el cliente o el backend)
  user_reputation  double precision not null default 1.0 check (user_reputation between 0 and 1),
  is_valid         boolean,                            -- null = sin evaluar; lo decide el backend
  is_simulated     boolean not null default false
);
create index if not exists reports_created_at_idx on public.reports (created_at desc);

-- ---------- bus_state (fila única id = 1) ----------
create table if not exists public.bus_state (
  id                     integer primary key default 1 check (id = 1),
  updated_at             timestamptz not null default now(),
  distance_m             double precision not null default 0,
  lat                    double precision not null,
  lng                    double precision not null,
  speed_mps              double precision not null default 0,
  confidence_score       double precision not null default 0 check (confidence_score between 0 and 1),
  status                 text not null default 'unknown',   -- unknown | moving | stopped | stale
  active_reports_count   integer not null default 0,
  rejected_trolls_count  integer not null default 0,
  etas_json              jsonb not null default '[]'::jsonb
);

-- Inicializada en el primer punto del LineString (distance_m = 0)
insert into public.bus_state (id, distance_m, lat, lng)
values (1, 0, -12.0602747, -77.0805066)
on conflict (id) do update
  set distance_m = 0, lat = excluded.lat, lng = excluded.lng,
      speed_mps = 0, confidence_score = 0, status = 'unknown',
      active_reports_count = 0, rejected_trolls_count = 0,
      etas_json = '[]'::jsonb, updated_at = now();

-- ---------- RLS deshabilitado (hackathon) ----------
alter table public.stops     disable row level security;
alter table public.reports   disable row level security;
alter table public.bus_state disable row level security;

-- ---------- Realtime ----------
alter table public.reports   replica identity full;
alter table public.bus_state replica identity full;

do $$
declare t text;
begin
  foreach t in array array['stops','reports','bus_state'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
