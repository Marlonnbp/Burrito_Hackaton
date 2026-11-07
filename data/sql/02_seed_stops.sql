-- =============================================================
-- Burrito Tracker UNMSM — 02_seed_stops.sql
-- distance_m = proyección Haversine de cada paradero sobre la LineString
-- de data/route_data.json (origen = primer vértice, loop cerrado L = 2677.29 m).
-- =============================================================

insert into public.stops (name, lat, lng, distance_m, order_index) values
  ('Paradero Puerta 2',    -12.0592551, -77.0796841,  168.44, 1),
  ('Paradero Puerta 3',    -12.0572138, -77.0802364,  403.05, 2),
  ('Paradero Puerta 7',    -12.0541984, -77.0846490, 1036.23, 3),
  ('Paradero FISI',        -12.0536854, -77.0857452, 1171.91, 4),
  ('Paradero Odontología', -12.0548592, -77.0861869, 1423.09, 5),
  ('Paradero Zulen',       -12.0560283, -77.0851156, 1668.37, 6),
  ('Paradero Puerta 1',    -12.0600919, -77.0844263, 2181.39, 7),
  ('Paradero Comedor',     -12.0608060, -77.0829508, 2404.34, 8),
  ('Paradero FII',         -12.0604165, -77.0808380, 2638.15, 9)
on conflict (name) do update
  set lat = excluded.lat, lng = excluded.lng,
      distance_m = excluded.distance_m, order_index = excluded.order_index;
