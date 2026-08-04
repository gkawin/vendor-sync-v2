alter table orders add column if not exists checked jsonb default '[]'::jsonb;
