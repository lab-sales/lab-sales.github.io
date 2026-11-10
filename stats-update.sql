-- =========================================================
-- Stats page update: adds the "viewing now" counter.
-- Run once in Supabase > SQL Editor. Your PIN is not changed.
-- =========================================================

-- Summary numbers for the stats page (PIN required)
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

  with s as (
    select * from public.pbi_sessions
     where started_at >= v_from
       and (p_report is null or report_key = p_report)
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
    'totals', (select json_build_object(
                  'views',           count(*),
                  'unique_visitors', count(distinct visitor_id),
                  'avg_seconds',     coalesce(round(avg(active_seconds)), 0),
                  'median_seconds',  coalesce(round(percentile_cont(0.5) within group (order by active_seconds)), 0),
                  'total_seconds',   coalesce(sum(active_seconds), 0),
                  'engaged',         count(*) filter (where engaged),
                  'bounces',         count(*) filter (where active_seconds < 10))
                 from s),
    'by_report', (select coalesce(json_agg(r order by r.views desc), '[]'::json) from (
                    select report_key,
                           count(*)                    as views,
                           count(distinct visitor_id)  as unique_visitors,
                           round(avg(active_seconds))  as avg_seconds,
                           sum(active_seconds)         as total_seconds
                      from s group by report_key) r),
    'daily', (select coalesce(json_agg(d order by d.day), '[]'::json) from (
                select (started_at at time zone 'Africa/Nairobi')::date as day,
                       count(*)                   as views,
                       count(distinct visitor_id) as visitors,
                       round(avg(active_seconds)) as avg_seconds
                  from s group by 1) d),
    'by_src', (select coalesce(json_agg(x order by x.views desc), '[]'::json) from (
                 select coalesce(src, 'direct') as label, count(*) as views
                   from s group by 1) x),
    'by_device', (select coalesce(json_agg(x order by x.views desc), '[]'::json) from (
                    select coalesce(device, 'unknown') as label, count(*) as views
                      from s group by 1) x),
    'recent', (select coalesce(json_agg(x), '[]'::json) from (
                 select started_at, report_key, coalesce(src, 'direct') as src,
                        device, active_seconds, engaged,
                        last_seen_at > now() - interval '45 seconds' as live
                   from s order by started_at desc limit 25) x)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_usage_stats(text, integer, text) from public;
grant execute on function public.get_usage_stats(text, integer, text) to anon;

