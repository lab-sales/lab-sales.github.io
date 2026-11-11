-- =========================================================
-- Rep name picker: reps choose their name before a dashboard opens,
-- and the stats page counts people by rep instead of by browser.
--
-- Run once in Supabase > SQL Editor (after schema.sql, stats.sql and
-- stats-update.sql). Then run reps-list.sql, which holds the names and
-- is kept out of this public repo. Your PIN and existing visits are kept.
-- =========================================================

-- 1) Rep list (readable only through get_reps below)
create table if not exists public.pbi_reps (
  rep_id       text primary key,              -- the number after the underscore, e.g. 9
  full_name    text not null,                 -- as in the HR list, e.g. JANE DOE
  display_name text not null,                 -- shown in the picker, e.g. Jane Doe
  active       boolean not null default true, -- false hides the name but keeps history
  added_at     timestamptz not null default now()
);
alter table public.pbi_reps enable row level security;
revoke all on table public.pbi_reps from anon, authenticated;

-- 2) Remember which rep each visit belongs to
alter table public.pbi_sessions add column if not exists rep_id   text;
alter table public.pbi_sessions add column if not exists rep_name text;
create index if not exists pbi_sessions_rep_idx on public.pbi_sessions (rep_id);

-- 3) Names for the picker (active reps only; no other data)
create or replace function public.get_reps()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object('id', rep_id, 'name', display_name) order by display_name), '[]'::json)
    from public.pbi_reps
   where active;
$$;

-- 4) Attach the chosen rep to the current visit (also used for "Not you? Change")
create or replace function public.track_rep(
  p_session_id uuid,
  p_rep_id     text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  select display_name into v_name from public.pbi_reps where rep_id = p_rep_id and active;
  if v_name is null then return; end if;
  update public.pbi_sessions
     set rep_id = p_rep_id, rep_name = v_name
   where session_id = p_session_id
     and started_at > now() - interval '12 hours';
end;
$$;

revoke all on function public.get_reps() from public;
revoke all on function public.track_rep(uuid, text) from public;
grant execute on function public.get_reps() to anon;
grant execute on function public.track_rep(uuid, text) to anon;

-- 5) Stats page numbers (PIN required). Same signature as before.
--
-- How "people" is counted:
--   * a visit with a chosen name counts as that rep
--   * older visits from a phone or browser where a rep later picked their
--     name are credited to that rep (so nobody is counted twice)
--   * older visits from browsers that never picked a name still count as
--     one person each, as before, so the count so far is not lost
create or replace function public.get_usage_stats(
  p_pin    text,
  p_days   integer default 30,   -- 0 or null = all time
  p_report text    default null  -- null = all dashboards
) returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash   text;
  v_from   timestamptz;
  v_result json;
begin
  if (select count(*) from public.pbi_auth_fails where at > now() - interval '10 minutes') >= 10 then
    return json_build_object('ok', false, 'error', 'Too many wrong attempts. Try again in 10 minutes.');
  end if;

  select value into v_hash from public.pbi_settings where key = 'stats_pin';
  if v_hash is null then
    return json_build_object('ok', false, 'error', 'No PIN set yet. Run set_stats_pin in Supabase.');
  end if;
  if crypt(coalesce(p_pin, ''), v_hash) <> v_hash then
    insert into public.pbi_auth_fails default values;
    return json_build_object('ok', false, 'error', 'Wrong PIN');
  end if;

  delete from public.pbi_auth_fails where at < now() - interval '1 day';

  v_from := case when coalesce(p_days, 0) <= 0 then '-infinity'::timestamptz
                 else date_trunc('day', now() at time zone 'Africa/Nairobi') at time zone 'Africa/Nairobi'
                      - make_interval(days => least(p_days, 3650) - 1) end;

  with dev as (            -- first rep ever chosen on each browser
    select distinct on (visitor_id) visitor_id, rep_id as dev_rep
      from public.pbi_sessions
     where rep_id is not null
     order by visitor_id, started_at
  ),
  s as (
    select p.*,
           coalesce(p.rep_id, d.dev_rep) as eff_rep,
           coalesce('r:' || coalesce(p.rep_id, d.dev_rep), 'd:' || p.visitor_id::text) as person
      from public.pbi_sessions p
      left join dev d on d.visitor_id = p.visitor_id
     where p.started_at >= v_from
       and (p_report is null or p.report_key = p_report)
  )
  select json_build_object(
    'ok', true,
    'generated_at', now(),
    'live_now', (select count(*) from public.pbi_sessions
                  where last_seen_at > now() - interval '45 seconds'
                    and (p_report is null or report_key = p_report)),
    'from', case when v_from = '-infinity' then null else (v_from at time zone 'Africa/Nairobi')::date end,
    'to', (now() at time zone 'Africa/Nairobi')::date,
    'reports', (select coalesce(json_agg(k order by k), '[]'::json)
                  from (select distinct report_key as k from public.pbi_sessions) r),
    'reps_total', (select count(*) from public.pbi_reps where active),
    'totals', (select json_build_object(
                  'views',           count(*),
                  'unique_visitors', count(distinct person),
                  'named_people',    count(distinct eff_rep),
                  'unnamed_people',  count(distinct person) filter (where eff_rep is null),
                  'avg_seconds',     coalesce(round(avg(active_seconds)), 0),
                  'median_seconds',  coalesce(round(percentile_cont(0.5) within group (order by active_seconds)), 0),
                  'total_seconds',   coalesce(sum(active_seconds), 0),
                  'engaged',         count(*) filter (where engaged),
                  'bounces',         count(*) filter (where active_seconds < 10))
                 from s),
    'by_report', (select coalesce(json_agg(r order by r.views desc), '[]'::json) from (
                    select report_key,
                           count(*)                    as views,
                           count(distinct person)      as unique_visitors,
                           count(distinct eff_rep)     as named_people,
                           round(avg(active_seconds))  as avg_seconds,
                           sum(active_seconds)         as total_seconds
                      from s group by report_key) r),
    'by_rep', (select coalesce(json_agg(x order by x.views desc, x.name), '[]'::json) from (
                 select r.rep_id, r.display_name as name,
                        count(s.session_id)                 as views,
                        coalesce(sum(s.active_seconds), 0)  as total_seconds,
                        max(s.started_at)                   as last_seen,
                        coalesce(json_agg(distinct s.report_key) filter (where s.report_key is not null), '[]'::json) as reports
                   from public.pbi_reps r
                   left join s on s.eff_rep = r.rep_id
                  group by r.rep_id, r.display_name, r.active
                 having r.active or count(s.session_id) > 0) x),
    'daily', (select coalesce(json_agg(d order by d.day), '[]'::json) from (
                select (started_at at time zone 'Africa/Nairobi')::date as day,
                       count(*)                   as views,
                       count(distinct person)     as visitors,
                       round(avg(active_seconds)) as avg_seconds
                  from s group by 1) d),
    'by_src', (select coalesce(json_agg(x order by x.views desc), '[]'::json) from (
                 select coalesce(src, 'direct') as label, count(*) as views
                   from s group by 1) x),
    'by_device', (select coalesce(json_agg(x order by x.views desc), '[]'::json) from (
                    select coalesce(device, 'unknown') as label, count(*) as views
                      from s group by 1) x),
    'recent', (select coalesce(json_agg(x), '[]'::json) from (
                 select s.started_at, s.report_key, coalesce(s.src, 'direct') as src,
                        s.device, s.active_seconds, s.engaged, rp.display_name as rep_name,
                        s.last_seen_at > now() - interval '45 seconds' as live
                   from s left join public.pbi_reps rp on rp.rep_id = s.eff_rep
                  order by s.started_at desc limit 25) x)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_usage_stats(text, integer, text) from public;
grant execute on function public.get_usage_stats(text, integer, text) to anon;
