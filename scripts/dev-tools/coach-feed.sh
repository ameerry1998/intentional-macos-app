#!/bin/zsh
# coach-feed.sh — live observability for the Focus Agent.
#
#   ./scripts/dev-tools/coach-feed.sh           one-shot snapshot (remote + local)
#   ./scripts/dev-tools/coach-feed.sh -f        follow the LOCAL describe/flush log live
#
# Local  = the dev app's own log: per-description engine + capture/inference timings.
# Remote = what actually reached the coach (events) and what it decided (verdicts).

LOG=/tmp/intentional-fresh.log
BACKEND_DIR="$(cd "$(dirname "$0")/../../../intentional-backend" 2>/dev/null && pwd)"

if [[ "$1" == "-f" ]]; then
  echo "── following local describe/telemetry log (ctrl-c to stop) ──"
  tail -f "$LOG" | grep --line-buffered -a "🫆 DESCRIBE\|CoachTelemetry flushed\|VLMDescriber"
  exit 0
fi

echo "════════ LOCAL: descriptions produced on this Mac (engine + timings) ════════"
grep -a "🫆 DESCRIBE" "$LOG" 2>/dev/null | tail -12 | sed 's/^[^🫆]*🫆/🫆/'
echo
echo "════════ LOCAL: model/download status ════════"
grep -a "VLMDescriber" "$LOG" 2>/dev/null | tail -4
echo

if [[ -n "$BACKEND_DIR" ]]; then
  cd "$BACKEND_DIR"
  eval "$(railway variables --service intentional-backend --kv 2>/dev/null | grep -E '^SUPABASE_(URL|SERVICE_KEY)=' | sed 's/^/export /')"
  if [[ -n "$SUPABASE_URL" ]]; then
    echo "════════ REMOTE: what reached the coach (last 20 events, ET) ════════"
    curl -s "$SUPABASE_URL/rest/v1/coach_events?select=ts,kind,payload&order=ts.desc&limit=20" \
      -H "apikey: $SUPABASE_SERVICE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_KEY" | python3 -c "
import json,sys
APP={'com.googlecode.iterm2':'iTerm2','com.google.Chrome':'Chrome','com.todesktop.Cursor':'Cursor','ai.perplexity.comet':'Comet'}
for r in reversed(json.load(sys.stdin)):
    p=r['payload']; h,m,s=r['ts'][11:19].split(':'); t=f'{(int(h)-4)%24}:{m}:{s}'
    k=r['kind']
    if k=='description':
        eng=p.get('engine','?').split(':')[0]
        print(f'{t}  🧠[{eng}] {p.get(\"description\",\"\")[:120]}')
    elif k=='sample':
        app=APP.get(p.get('app',''),p.get('app','?')); host=p.get('host'); title=(p.get('title') or '')[:48]
        loc=f'{app}·{host}' if host else app
        print(f'{t}  {loc:30} {title}')
    else:
        print(f'{t}  ⚡ {k} {json.dumps(p)[:80]}')"
    echo
    echo "════════ REMOTE: coach verdicts (last 5) ════════"
    curl -s "$SUPABASE_URL/rest/v1/coach_decisions?select=ts,action,message,why,shadow,outcome&order=ts.desc&limit=5" \
      -H "apikey: $SUPABASE_SERVICE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_KEY" | python3 -c "
import json,sys
for d in reversed(json.load(sys.stdin)):
    h,m,s=d['ts'][11:19].split(':')
    shadow='shadow' if d['shadow'] else 'LIVE'
    print(f\"{(int(h)-4)%24}:{m}  {d['action'].upper():11} [{shadow}] {(d.get('why') or '')[:110]}\")
    if d.get('message'): print(f'        💬 {d[\"message\"][:115]}')
    if d.get('outcome'): print(f'        ↳ outcome: {d[\"outcome\"]}')"
  else
    echo "(remote skipped — railway credentials unavailable)"
  fi
fi