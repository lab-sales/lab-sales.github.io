-- =========================================================
-- Power BI Publish to Web usage tracker: Supabase setup
-- Run once in Supabase > SQL Editor
-- =========================================================

-- 1) Sessions table (one row per visit)
create table if not exists public.pbi_sessions (
  session_id     uuid primary key,
  visitor_id     uuid not null,
  report_key     text not null default 'default',
  started_at     timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  active_seconds integer not null default 0,     -- time with the tab visible
  engaged        boolean not null default false, -- clicked into the report
  src            text,                           -- ?src= tag (whatsapp, linkedin, email...)
  referrer       text,
  device         text,
  screen         text,
  language       text,
  timezone       text,
  country        text,                           -- best effort, from request headers
  user_agent     text
);

create index if not exists pbi_sessions_started_idx on public.pbi_sessions (started_at);
create index if not exists pbi_sessions_visitor_idx on public.pbi_sessions (visitor_id);

-- Lock the table: the browser can only write through the two functions below
alter table public.pbi_sessions enable row level security;
revoke all on table public.pbi_sessions from anon, authenticated;

-- 2) Start a session
create or replace function public.track_start(
  p_session_id uuid,
  p_visitor_id uuid,
  p_report_key text,
  p_src        text,
  p_referrer   text,
  p_device     text,
  p_screen     text,
  p_language   text,
  p_timezone   text,
  p_user_agent text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_country text;
begin
  begin
    v_country := nullif(current_setting('request.headers', true)::json ->> 'cf-ipcountry', '');
  exception when others then
    v_country := null;
  end;

  insert into public.pbi_sessions (
    session_id, visitor_id, report_key, src, referrer, device, screen,
    language, timezone, country, user_agent
  ) values (
    p_session_id, p_visitor_id,
    left(coalesce(p_report_key, 'default'), 64),
    left(p_src, 64), left(p_referrer, 500), left(p_device, 16), left(p_screen, 20),
    left(p_language, 20), left(p_timezone, 64), left(v_country, 8), left(p_user_agent, 300)
  )
  on conflict (session_id) do nothing;
end;
$$;

-- 3) Heartbeat: add active time (capped against abuse)
create or replace function public.track_ping(
  p_session_id   uuid,
  p_active_delta integer,
  p_engaged      boolean default false
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.pbi_sessions
     set active_seconds = least(active_seconds + greatest(0, least(coalesce(p_active_delta, 0), 60)), 14400),
         engaged        = engaged or coalesce(p_engaged, false),
         last_seen_at   = now()
   where session_id = p_session_id
     and started_at > now() - interval '12 hours';
end;
$$;

revoke all on function public.track_start(uuid, uuid, text, text, text, text, text, text, text, text) from public;
revoke all on function public.track_ping(uuid, integer, boolean) from public;
grant execute on function public.track_start(uuid, uuid, text, text, text, text, text, text, text, text) to anon;
grant execute on function public.track_ping(uuid, integer, boolean) to anon;

-- =========================================================
-- 4) Reporting views (separate schema, NOT exposed to the web API)
-- =========================================================
create schema if not exists analytics;

create or replace view analytics.sessions as
select
  session_id,
  visitor_id,
  report_key,
  started_at at time zone 'Africa/Nairobi'               as started_at_eat,
  (started_at at time zone 'Africa/Nairobi')::date       as visit_date,
  extract(hour from started_at at time zone 'Africa/Nairobi')::int as visit_hour,
  active_seconds,
  round(active_seconds / 60.0, 2)                         as active_minutes,
  active_seconds < 10                                     as is_bounce,
  engaged,
  coalesce(src, 'direct')                                 as src,
  referrer, device, screen, language, timezone, country,
  row_number() over (partition by visitor_id order by started_at) = 1 as is_first_visit
from public.pbi_sessions;

create or replace view analytics.daily_usage as
select
  visit_date,
  report_key,
  count(*)                                                     as sessions,
  count(distinct visitor_id)                                   as unique_visitors,
  count(*) filter (where is_first_visit)                       as new_visitors,
  round(avg(active_seconds) / 60.0, 2)                         as avg_active_minutes,
  round((percentile_cont(0.5) within group (order by active_seconds) / 60.0)::numeric, 2) as median_active_minutes,
  round(sum(active_seconds) / 3600.0, 2)                       as total_active_hours,
  count(*) filter (where engaged)                              as engaged_sessions,
  count(*) filter (where is_bounce)                            as bounces
from analytics.sessions
group by visit_date, report_key;

-- =========================================================
-- 5) Read-only login for Power BI (change the password)
-- =========================================================
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'powerbi_reader') then
    create role powerbi_reader login password 'CHANGE_ME_STRONG_PASSWORD';
  end if;
end $$;

grant usage on schema analytics to powerbi_reader;
grant select on all tables in schema analytics to powerbi_reader;
