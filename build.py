"""
Builds one private page per team dashboard.

Each team's page lives at a link with a private code (e.g. /noiva-sales-1e0ff1eb/)
and contains only that team's Power BI link. There is no menu and no way to move
between dashboards from inside a page.

To add, rename or remove a dashboard: edit DASHBOARDS below, run `python3 build.py`,
then commit. Keep the code (4th field) the same, or the team's link will change.
New code: python3 -c "import secrets; print(secrets.token_hex(4))"
"""
import json, os, shutil, html

SUPABASE_URL = "https://slygodiwvaaqxtwekupi.supabase.co"
SUPABASE_KEY = "sb_publishable_p7aJfsR1f8PO1YDcpt7aqw_n55TljCG"

# tracking key, title, team, private code, Power BI publish-to-web link
DASHBOARDS = [
    ("full-sales", "Full Sales", "All teams", "2db7ae3d",
     "https://app.powerbi.com/view?r=eyJrIjoiYTAxNTExZDktYzk2ZS00MWNkLTk5MjEtZTNiNGExYjBmYTRhIiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("key-accounts-sales", "Key Accounts Sales", "Key Accounts team", "edba849a",
     "https://app.powerbi.com/view?r=eyJrIjoiNDQzZWJiYzEtNzkyZi00ODNjLWE1M2ItZDJjMWZmYTA0ZGE5IiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("open-market-sales", "Open Market Sales", "Open Market team", "d7b740c0",
     "https://app.powerbi.com/view?r=eyJrIjoiYTZlYmNiYTktOGE1OC00MTI5LWEwNDctZjFlZjBhMTIzMzNkIiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("noiva-sales", "Noiva Sales", "Noiva team", "1e0ff1eb",
     "https://app.powerbi.com/view?r=eyJrIjoiMTRkOWZmMTgtODVhOS00Y2ZlLWE4Y2YtOGJkY2IwZmQ2MGVmIiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("travega-sales", "Travega Sales", "Travega team", "275d8f21",
     "https://app.powerbi.com/view?r=eyJrIjoiMGEyZDQ0NTUtN2I3NC00M2QwLWJjOTUtOTcyMTM5MTQwODg5IiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("magnovia-sales", "Magnovia Sales", "Magnovia team", "e8521c35",
     "https://app.powerbi.com/view?r=eyJrIjoiYTUyODE2OTgtMDE2OS00NzJjLWEyNzMtZDc3OTg5NDhkMTg0IiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
    ("market-access-sales", "Market Access Sales", "Market Access team", "56f979fb",
     "https://app.powerbi.com/view?r=eyJrIjoiYTZlYmNiYTktOGE1OC00MTI5LWEwNDctZjFlZjBhMTIzMzNkIiwidCI6ImVkY2YyOTM1LTE4ZDQtNDg1Ni1iM2Q3LWEzMjEyM2JhZjgwOCIsImMiOjh9"),
]

ROOT = os.path.dirname(os.path.abspath(__file__))
import hashlib
VIEWER_JS = open(os.path.join(ROOT, "assets", "viewer.js")).read()
VER = hashlib.sha1(open(os.path.join(ROOT, "assets", "portal.css"), "rb").read()).hexdigest()[:8]
SITE = "https://lab-sales.github.io/"

VIEWER = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>{title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,700&family=Instrument+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="../assets/portal.css?v={ver}">
</head>
<body class="viewer">
<header class="vbar">
  <span class="vtitle"><span class="dot"></span>{title}</span>
  <span class="vright"><span class="vteam">{team}</span><button class="vwho" id="who" type="button" hidden></button></span>
</header>
<iframe id="report" title="{title}" allowfullscreen></iframe>
<p class="note">Usage statistics (the name you pick, visits and time on page) are collected to improve this dashboard. No IP addresses are stored.</p>
<script>window.PORTAL = {config};</script>
<script>
{viewer_js}
</script>
</body>
</html>
"""

# Remove generated folders that are no longer listed
wanted = {f"{k}-{code}" for k, _, _, code, _ in DASHBOARDS}
for name in os.listdir(ROOT):
    p = os.path.join(ROOT, name)
    if os.path.isdir(p) and os.path.exists(os.path.join(p, ".generated")) and name not in wanted:
        shutil.rmtree(p)

links = []
for key, title, team, code, url in DASHBOARDS:
    folder = f"{key}-{code}"
    cfg = {"SUPABASE_URL": SUPABASE_URL, "SUPABASE_KEY": SUPABASE_KEY, "HEARTBEAT_SECONDS": 15,
           "REPORT": {"key": key, "title": title, "url": url}}
    d = os.path.join(ROOT, folder)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "index.html"), "w") as f:
        f.write(VIEWER.format(title=html.escape(title), team=html.escape(team),
                              config=json.dumps(cfg).replace("</", "<\\/"),
                              viewer_js=VIEWER_JS, ver=VER))
    open(os.path.join(d, ".generated"), "w").close()
    links.append(f"{team}: {SITE}{folder}/")

print("Built", len(DASHBOARDS), "dashboards:\n" + "\n".join(links))
