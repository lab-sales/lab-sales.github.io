# Power BI Publish to Web Usage Tracker

Tracks visits, unique visitors and active time for a Power BI "Publish to web" report by hosting it inside your own page.

## What gets tracked

- **Visits (sessions):** one row each time the page is opened
- **Unique and returning visitors:** anonymous ID stored in the browser
- **Active time:** counted only while the tab is visible, sent every 15 seconds
- **Engaged:** whether the visitor clicked into the report at all
- **Source:** from the `?src=` tag on the link you share (whatsapp, linkedin, email...)
- **Context:** device type, screen size, language, timezone, referrer, country (best effort)

Not tracked: clicks inside the report (slicers, page tabs). Publish to Web blocks that; it needs Power BI Embedded.

## Files

| File | Purpose |
|---|---|
| `index.html`, `404.html` | Neutral landing page. No list of dashboards |
| `<dashboard>-<code>/index.html` | One private page per team, holding only that team's Power BI link (generated) |
| `build.py` | The dashboard list and private codes. Edit it and run it to add or change dashboards |
| `assets/` | Shared styles and the tracker script |
| `schema.sql` | Supabase table, tracking functions, reporting views, read-only Power BI login |
| `stats.html` | PIN-protected page showing views and time spent |
| `stats.sql`, `stats-update.sql` | Supabase setup for the stats page |
| `reps-update.sql` | Rep name picker: rep table, `get_reps`, `track_rep`, people counted by rep |

## Team links

Each team gets a private link with a code (for example `/noiva-sales-xxxxxxxx/`). Run `python3 build.py` to print the current list. Pages have no menu or "all dashboards" button, so a team can only see the dashboard it was sent.

Open `https://lab-sales.github.io/?notrack=1` once on each of your own devices so your visits are not counted.

## Rep name picker

Before a dashboard opens, the rep picks their name from a searchable list. It is asked once per phone or browser, and the name shows top right with a "Change" option. The stats page then counts **people by rep** and lists who has and hasn't opened a dashboard.

- Names live in Supabase (`pbi_reps`), not in this repo. Only first-time visitors' browsers fetch them, through `get_reps`.
- Setup: run `reps-update.sql`, then the private `reps-list.sql` (kept outside this public repo) in the Supabase SQL Editor.
- Add a rep: insert a row (or add a line to `reps-list.sql` and re-run it). Remove: `update public.pbi_reps set active = false where rep_id = '123';` (history is kept).
- Your own devices that opened `?notrack=1` skip the picker. Add `&picker=1` to preview it.
- If the name list can't be loaded, the dashboard opens anyway, so nobody is locked out.

How people are counted: a visit with a name counts as that rep. Earlier visits from the same browser are credited to the rep who later picks a name there. Browsers that never picked a name still count as one person each, so the earlier count is kept.

## Stats page

See views and time spent at:
https://lab-sales.github.io/stats.html

It is PIN protected and not linked from the public menu.

To set it up, run `stats.sql` in the Supabase SQL Editor after changing the PIN on its last line (8+ characters). To change the PIN later, run:
```sql
select public.set_stats_pin('YourNewPin');
```
After 10 wrong PIN attempts the page locks for 10 minutes.

The page refreshes itself every 30 seconds while open, and shows how many people are viewing a dashboard right now (needs `stats-update.sql`, run once).

## Setup

### 1. Supabase (turns tracking on)
Until this is done the dashboards display normally but nothing is recorded.
1. Create a free project at supabase.com.
2. Open the **SQL Editor**, paste `schema.sql`, change `CHANGE_ME_STRONG_PASSWORD`, and run it.
3. In the project's API settings, copy the **Project URL** and the **anon / publishable key**.

### 2. Add, rename or remove a dashboard
1. Edit the `DASHBOARDS` list in `build.py` (keep existing codes so links don't change).
2. Run `python3 build.py`. It rewrites the dashboard folders and prints the links.
3. Commit and push. GitHub Pages updates in about a minute.

The Supabase URL and key also live in `build.py`. The key is public by design: the browser can only call the two tracking functions and cannot read the data.

### 3. Connect Power BI to the data
1. In Supabase, open **Connect** and copy the **Session pooler** host (it supports IPv4; the direct host may not).
2. Power BI Desktop: **Get Data > PostgreSQL database**
   - Server: `<pooler-host>:5432`
   - Database: `postgres`
   - User: `powerbi_reader.<project-ref>` (pooler format), password from step 1
3. Load `analytics.daily_usage` and `analytics.sessions`. Filter by `report_key` (e.g. `noiva-sales`, `full-sales`) to compare dashboards.

## Useful measures (DAX)

```dax
Sessions        = COUNTROWS ( sessions )
Unique Visitors = DISTINCTCOUNT ( sessions[visitor_id] )
Avg Active Min  = AVERAGE ( sessions[active_minutes] )
Bounce Rate     = DIVIDE ( CALCULATE ( [Sessions], sessions[is_bounce] = TRUE () ), [Sessions] )
Engagement Rate = DIVIDE ( CALCULATE ( [Sessions], sessions[engaged] = TRUE () ), [Sessions] )
```

## Notes

- **Old links:** anyone using the original Power BI link bypasses tracking. To force traffic through your page, delete the old embed code under **Settings > Manage embed codes** and publish a new one. This breaks the old link.
- **Country** is read from request headers and may be empty. Timezone is a reliable fallback for Kenya vs elsewhere.
- **Idle tabs:** a visible tab left open still counts. Time is capped at 4 hours per session; use the median in reporting.
- **Privacy:** no names, emails or IP addresses are stored, and the page shows a short notice. This fits the Kenya Data Protection Act's transparency principle, but confirm with your compliance team if this is a company report.
- Publish to Web reports are fully public. Do not use it for confidential company data.

## How it was built and tested

- **Front end:** plain HTML and JavaScript, Page Visibility API for active time, `fetch` with `keepalive` for the exit ping
- **Back end:** Supabase (Postgres) with `SECURITY DEFINER` functions, row level security, and input caps against abuse
- **Tested:** JS syntax checked with Node; SQL run on a local PostgreSQL 16 with Supabase-style `anon` roles, confirming inserts, the 60 second per-ping cap, the anon read block, and the reporting views
