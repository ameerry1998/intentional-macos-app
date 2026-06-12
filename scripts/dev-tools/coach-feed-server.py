#!/usr/bin/env python3
"""Live Focus-Agent feed at http://localhost:8765 — polls Supabase + the local
dev log every refresh. Needs SUPABASE_URL / SUPABASE_SERVICE_KEY in env
(launcher: scripts/dev-tools/coach-feed-live.sh). Dev tool — localhost only."""
import json, os, re, urllib.request
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

SB = os.environ.get("SUPABASE_URL", "")
KEY = os.environ.get("SUPABASE_SERVICE_KEY", "")
LOG = "/tmp/intentional-fresh.log"
PORT = 8799

def sb_get(path):
    req = urllib.request.Request(f"{SB}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)

def local_describes():
    out = []
    try:
        with open(LOG, "rb") as f:
            f.seek(max(0, os.path.getsize(LOG) - 400_000))
            text = f.read().decode("utf-8", "replace")
        for line in text.splitlines():
            if "🫆 DESCRIBE" in line:
                m = re.search(r"(\d{2}:\d{2}:\d{2})", line)
                out.append({"t": m.group(1) if m else "", "line": line[line.index("🫆"):]})
    except OSError:
        pass
    return out[-40:]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        if self.path == "/data.json":
            day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            try:
                events = sb_get(f"coach_events?select=ts,kind,payload&ts=gte.{day}T00:00:00&order=ts.asc&limit=800")
                decisions = sb_get(f"coach_decisions?select=ts,action,message,why,shadow,outcome&ts=gte.{day}T00:00:00&order=ts.asc&limit=200")
                self._send(json.dumps({"events": events, "decisions": decisions,
                                       "local": local_describes()}), "application/json")
            except Exception as e:
                self._send(json.dumps({"error": str(e)}), "application/json")
        else:
            self._send(PAGE, "text/html")

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Focus Agent — LIVE</title><style>
body{background:#0a0c0a;color:#eee;font:13px/1.6 ui-monospace,Menlo,monospace;max-width:1100px;margin:0 auto;padding:24px 20px 60px}
h1{font:700 18px -apple-system,sans-serif;color:#FF7A2E;display:flex;align-items:center;gap:10px}
#live{width:9px;height:9px;border-radius:50%;background:#5dbf7a;animation:p 2s infinite}@keyframes p{50%{opacity:.3}}
.sub{color:#888;font:12px -apple-system,sans-serif;margin-bottom:16px}
.t{color:#666;margin-right:8px}.sample{color:#9aa}.title{color:#778}
.desc{color:#e8d9b0;margin:2px 0}.desc.vlm{color:#ffd27e}.eng{color:#5a8;font-size:11px}
.decision{color:#9fd0ff;margin:6px 0;padding:6px 10px;border-left:2px solid #36c;background:rgba(60,100,200,.07)}
.decision.live{border-color:#FF7A2E;background:rgba(255,122,46,.1)}
.dmsg{color:#fff;margin-top:3px}.sess{color:#5dbf7a}.boundary{color:#d9a441}
#timing{margin:14px 0;padding:10px;border:1px solid #333;border-radius:8px;color:#9c8}
#timing div{white-space:pre-wrap;word-break:break-all}
.new{animation:hl 3s}@keyframes hl{0%{background:rgba(255,179,71,.25)}100%{background:none}}
</style></head><body>
<h1><span id="live"></span>Focus Agent — live feed</h1>
<div class="sub">Auto-updates every 15s. <span id="status">connecting…</span></div>
<div id="timing"><b style="color:#FF7A2E;font-family:-apple-system">local describe pipeline (timings)</b></div>
<div id="feed"></div>
<script>
const APP={'com.googlecode.iterm2':'iTerm2','com.google.Chrome':'Chrome','com.todesktop.Cursor':'Cursor','ai.perplexity.comet':'Comet','net.whatsapp.WhatsApp':'WhatsApp','com.loki-project.messenger-desktop':'Session'};
const seen=new Set();
const esc=s=>(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const et=ts=>{const[h,m]=ts.slice(11,19).split(':');return ((+h+20)%24)+':'+m};
function row(o){
  if(o.k==='dec'){const d=o.d,live=!d.shadow;
    return `<div class="decision${live?' live':''}"><span class="t">${et(d.ts)}</span> ⚖️ COACH: <b>${d.action.toUpperCase()}</b> <span class="eng">[${live?'LIVE':'shadow'}${d.outcome?' → '+d.outcome:''}]</span> — ${esc((d.why||'').slice(0,200))}${d.message?`<div class="dmsg">💬 ${esc(d.message)}</div>`:''}</div>`}
  const r=o.d,p=r.payload||{};
  if(r.kind==='description'){const eng=(p.engine||'?').split(':')[0];
    return `<div class="desc ${eng==='vlm'?'vlm':''}"><span class="t">${et(r.ts)}</span> 🧠 <span class="eng">[${eng}]</span> ${esc(p.description)}</div>`}
  if(r.kind==='sample'){const app=APP[p.app]||p.app||'?',loc=p.host?`${app} · ${p.host}`:app;
    return `<div class="sample"><span class="t">${et(r.ts)}</span> ${loc} <span class="title">${esc((p.title||'').slice(0,70))}</span>${p.in_session?' <span class="sess">●session</span>':''}</div>`}
  return `<div class="boundary"><span class="t">${et(r.ts)}</span> ⚡ ${r.kind} ${esc(JSON.stringify(p).slice(0,80))}</div>`}
async function tick(){
  try{
    const d=await (await fetch('/data.json')).json();
    if(d.error){document.getElementById('status').textContent='error: '+d.error;return}
    const items=[...d.events.map(e=>({k:'ev',ts:e.ts,key:e.ts+e.kind+JSON.stringify(e.payload),d:e})),
                 ...d.decisions.map(x=>({k:'dec',ts:x.ts,key:'dec'+x.ts+(x.outcome||''),d:x}))]
      .sort((a,b)=>a.ts<b.ts?-1:1);
    const feed=document.getElementById('feed');
    const atBottom=innerHeight+scrollY>=document.body.scrollHeight-80;
    for(const it of items){
      if(seen.has(it.key))continue;
      seen.add(it.key);
      const div=document.createElement('div');div.innerHTML=row(it);div.firstChild.classList.add('new');
      feed.appendChild(div.firstChild)}
    document.getElementById('timing').innerHTML='<b style="color:#FF7A2E;font-family:-apple-system">local describe pipeline (timings)</b>'+
      d.local.slice(-6).map(l=>`<div>${esc(l.line)}</div>`).join('');
    document.getElementById('status').textContent='live · last update '+new Date().toLocaleTimeString();
    if(atBottom)scrollTo(0,document.body.scrollHeight)}
  catch(e){document.getElementById('status').textContent='fetch failed: '+e}}
tick();setInterval(tick,15000);
</script></body></html>"""

if __name__ == "__main__":
    print(f"coach feed live at http://localhost:{PORT}")
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
