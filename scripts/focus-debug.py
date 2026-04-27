#!/usr/bin/env python3
"""Live focus-state dashboard.

Generates an HTML page showing the current state of cross-device focus
across iPhone, backend, and Mac. Run on Mac. Opens in browser.

Usage:
    python3 scripts/focus-debug.py        # generate + open
    python3 scripts/focus-debug.py --no-open

Re-run to refresh. Snapshot in time; doesn't auto-update.
"""
from __future__ import annotations

import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.request
import urllib.error

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
LOG_PATH = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"]).decode().strip() + "intentional-debug.log"
STATE_PATH = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"]).decode().strip() + "intentional-focus-state.json"
HTML_OUT = "/tmp/focus-debug.html"
KEYCHAIN_SERVICE = "com.intentional.auth"
BACKEND = "https://api.intentional.social"
NOW = dt.datetime.now(dt.timezone.utc)


def keychain_get(account: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return out or None
    except subprocess.CalledProcessError:
        return None


def http_get_json(path: str, token: str | None) -> tuple[int, dict | str]:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BACKEND + path, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            body = r.read().decode()
            try:
                return r.status, json.loads(body)
            except json.JSONDecodeError:
                return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception as e:
        return -1, str(e)


def decode_jwt_exp(token: str) -> dt.datetime | None:
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return None
        payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        exp = payload.get("exp")
        if exp is None:
            return None
        return dt.datetime.fromtimestamp(int(exp), dt.timezone.utc)
    except Exception:
        return None


def app_processes() -> list[tuple[str, str, str]]:
    """Return (pid, lstart, command) tuples for running Intentional processes."""
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pid,lstart,command"], stderr=subprocess.DEVNULL
        ).decode()
        rows = []
        for line in out.splitlines():
            if "Intentional.app/Contents/MacOS/Intentional" in line and "grep" not in line:
                parts = line.split(None, 6)  # pid, weekday, mon, day, time, year, command
                if len(parts) == 7:
                    pid = parts[0]
                    lstart = " ".join(parts[1:6])
                    cmd = parts[6]
                    is_relay = "chrome-extension" in cmd
                    rows.append((pid, lstart, cmd, is_relay))
        return rows
    except subprocess.CalledProcessError:
        return []


def tail_log(filter_keywords: list[str], max_lines: int = 60) -> list[str]:
    if not os.path.exists(LOG_PATH):
        return []
    try:
        # Read last 5000 lines, filter, take last N
        out = subprocess.check_output(["tail", "-n", "5000", LOG_PATH]).decode("utf-8", errors="replace")
        matched = [
            line for line in out.splitlines()
            if any(k in line for k in filter_keywords)
        ]
        return matched[-max_lines:]
    except Exception:
        return []


def human_delta(target: dt.datetime, now: dt.datetime = NOW) -> str:
    """Return e.g. 'in 47m', '23s ago', '4h 12m ago'."""
    seconds = int((target - now).total_seconds())
    sign = "in " if seconds >= 0 else ""
    suffix = "" if seconds >= 0 else " ago"
    s = abs(seconds)
    if s < 60:
        return f"{sign}{s}s{suffix}"
    if s < 3600:
        return f"{sign}{s // 60}m{suffix}"
    h = s // 3600
    m = (s % 3600) // 60
    return f"{sign}{h}h {m}m{suffix}"


def parse_log_ts(line: str) -> dt.datetime | None:
    m = re.match(r"^\[([\d\-T:Z]+)\]", line)
    if not m:
        return None
    try:
        return dt.datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
    except ValueError:
        return None


# ----------------------------------------------------------------------
# Gather state
# ----------------------------------------------------------------------
def read_mac_live_state() -> tuple[dict | None, dt.datetime | None]:
    """Read the ground-truth Mac focus state dumped by AppDelegate every 5s.

    Returns (state_dict, file_mtime) or (None, None) if not present. The mtime
    tells us how stale the snapshot is (new builds dump every 5s, so mtime > 30s
    ago means the app may not be running or the state-dump timer is broken).
    """
    if not os.path.exists(STATE_PATH):
        return None, None
    try:
        mtime = dt.datetime.fromtimestamp(os.path.getmtime(STATE_PATH), tz=dt.timezone.utc)
        with open(STATE_PATH) as f:
            return json.load(f), mtime
    except Exception:
        return None, None


def gather() -> dict:
    state: dict = {"now": NOW.isoformat(), "log_path": LOG_PATH, "state_path": STATE_PATH}

    # Live state from Mac app (preferred — ground truth)
    live, live_mtime = read_mac_live_state()
    state["mac_live"] = live
    state["mac_live_mtime"] = live_mtime.isoformat() if live_mtime else None
    state["mac_live_age_seconds"] = (NOW - live_mtime).total_seconds() if live_mtime else None
    state["mac_live_fresh"] = (
        live_mtime is not None and (NOW - live_mtime).total_seconds() < 30
    )

    # 1. Tokens
    access = keychain_get("access_token")
    refresh = keychain_get("refresh_token")
    state["access_token_present"] = bool(access)
    state["refresh_token_present"] = bool(refresh)
    state["access_token_exp"] = decode_jwt_exp(access).isoformat() if access else None
    state["access_token_status"] = (
        "missing" if not access
        else "expired" if state["access_token_exp"] and dt.datetime.fromisoformat(state["access_token_exp"]) < NOW
        else "valid"
    )

    # 2. Backend session state
    if access:
        status, body = http_get_json("/focus/active", access)
        state["focus_active_http"] = status
        state["focus_active_body"] = body
        status, body = http_get_json("/auth/me", access)
        state["auth_me_http"] = status
        state["auth_me_body"] = body
    else:
        state["focus_active_http"] = None
        state["focus_active_body"] = None
        state["auth_me_http"] = None
        state["auth_me_body"] = None

    # 3. Mac process
    state["processes"] = app_processes()

    # 4. Mac WS state — infer from log
    ws_lines = tail_log(["🔌 WebSocket connected", "🔌 WebSocket disconnected", "🔌 WebSocket auth expired"], 20)
    state["ws_log"] = ws_lines
    last_ws_event = None
    last_ws_state = "unknown"
    for ln in reversed(ws_lines):
        if "WebSocket connected" in ln:
            last_ws_state = "connected"
            last_ws_event = parse_log_ts(ln)
            break
        if "WebSocket disconnected" in ln:
            last_ws_state = "disconnected"
            last_ws_event = parse_log_ts(ln)
            break
    state["ws_state"] = last_ws_state
    state["ws_last_event"] = last_ws_event.isoformat() if last_ws_event else None

    # 5. Mac focus session state — infer from log
    fs_lines = tail_log([
        "🎯 Focus session started",
        "🎯 Focus session ended",
        "🎯 Focus session has no profiles",
        "🎯 startFocusSession",
        "📋 Block changed",
        "🧘 Block ritual",
    ], 15)
    state["focus_log"] = fs_lines
    last_focus_state = "idle"
    last_focus_event = None
    for ln in reversed(fs_lines):
        if "Focus session started" in ln:
            last_focus_state = "engaged"
            last_focus_event = parse_log_ts(ln)
            break
        if "Focus session ended" in ln:
            last_focus_state = "ended"
            last_focus_event = parse_log_ts(ln)
            break
        if "skipping enforcement" in ln:
            last_focus_state = "phantom (no enforcement)"
            last_focus_event = parse_log_ts(ln)
            break
    state["focus_state"] = last_focus_state
    state["focus_last_event"] = last_focus_event.isoformat() if last_focus_event else None

    # 6. Recent focus signals received via WS
    state["recent_signals"] = tail_log([
        "🔌 Focus signal: START",
        "🔌 Focus signal: STOP",
        "🔌 Found active Puck focus session",
    ], 10)

    # 7. Recent auth-refresh events
    state["recent_auth"] = tail_log([
        "🔌 DeviceRegister",
        "🔌 Token refresh",
        "🔌 WebSocket auth expired",
    ], 10)

    return state


# ----------------------------------------------------------------------
# Render HTML
# ----------------------------------------------------------------------
def pill(label: str, kind: str) -> str:
    return f'<span class="pill pill-{kind}">{label}</span>'


def bool_pill(value: bool, true_label: str = "yes", false_label: str = "no") -> str:
    return pill(true_label if value else false_label, "ok" if value else "bad")


def status_pill(status: str) -> str:
    kind = {
        "valid": "ok",
        "connected": "ok",
        "engaged": "ok",
        "missing": "bad",
        "expired": "bad",
        "disconnected": "bad",
        "phantom (no enforcement)": "warn",
        "ended": "muted",
        "idle": "muted",
        "unknown": "muted",
    }.get(status, "muted")
    return pill(status.upper(), kind)


def section(title: str, icon: str, body: str) -> str:
    return f"""
    <section class="card">
      <h2><span class="ico">{icon}</span>{title}</h2>
      {body}
    </section>
    """


def src_pill(source: str) -> str:
    """Tag each value with where it came from so the user knows what to trust.
    `live`     = ground truth from Mac state dump
    `api`      = ground truth from backend HTTP call
    `system`   = ground truth from macOS (security, ps, file mtime)
    `inferred` = approximated from log scraping (may be stale or missing events)
    """
    cls = {"live": "src-live", "api": "src-live", "system": "src-live", "inferred": "src-inferred"}.get(source, "src-inferred")
    label = {"live": "LIVE", "api": "API", "system": "SYS", "inferred": "LOG"}.get(source, "?")
    return f'<span class="src {cls}">{label}</span>'


def render(state: dict) -> str:
    fa = state["focus_active_body"] if isinstance(state.get("focus_active_body"), dict) else {}
    me = state["auth_me_body"] if isinstance(state.get("auth_me_body"), dict) else {}
    live = state.get("mac_live") or {}
    live_fresh = state.get("mac_live_fresh", False)

    # Boundary checks (prefer live state when available)
    iphone_active = isinstance(fa, dict) and bool(fa.get("active"))
    # Treat any HTTP response (even 401) as "backend reachable" — the server
    # answered, just disagreed about auth. Network/DNS failure returns -1.
    backend_http = state.get("focus_active_http")
    backend_reachable = isinstance(backend_http, int) and backend_http >= 0
    backend_auth_ok = backend_http == 200
    if live_fresh:
        ws_connected = bool(live.get("websocket", {}).get("is_connected"))
        mac_session_active = bool(live.get("focus_session", {}).get("active"))
        mac_block_present = bool(live.get("current_block", {}).get("present"))
        mac_engaged = mac_session_active and mac_block_present
        mac_phantom = mac_session_active and not mac_block_present  # session active but no block injected
    else:
        ws_connected = state["ws_state"] == "connected"
        mac_engaged = state["focus_state"] == "engaged"
        mac_phantom = state["focus_state"] == "phantom (no enforcement)"

    # Match logic
    in_sync = iphone_active == mac_engaged
    sync_pill = (
        pill("✅ IN SYNC", "ok") if in_sync
        else pill("⚠️ MAC AHEAD", "warn") if mac_engaged and not iphone_active
        else pill("⚠️ MAC BEHIND", "warn")
    )
    if mac_phantom and not iphone_active:
        sync_pill = pill("⚠️ PHANTOM ON MAC", "warn")

    # ----- Cross-device summary -----
    summary_rows = []
    summary_rows.append((f"{src_pill('api')} 📱 Phone session in backend", bool_pill(iphone_active, "active", "none")))
    if iphone_active:
        summary_rows.append((f"{src_pill('api')}     Started", f'<code>{fa.get("started_at", "?")}</code>'))
        summary_rows.append((f"{src_pill('api')}     Triggered by", f'<code>{fa.get("triggered_by", "?")}</code>'))
        summary_rows.append((f"{src_pill('api')}     Session ID", f'<code>{fa.get("session_id", "?")[:12]}…</code>'))

    if live_fresh:
        # Ground truth from Mac
        ms = live.get("focus_session", {})
        cb = live.get("current_block", {})
        if ms.get("active"):
            summary_rows.append((f"{src_pill('live')} 💻 Mac session active", pill("YES", "ok")))
            summary_rows.append((f"{src_pill('live')}     Intention", f'<code>{(ms.get("intention") or "(none)")}</code>'))
            summary_rows.append((f"{src_pill('live')}     Profile IDs", f'<code>{len(ms.get("profileIds", []))} profile(s)</code>'))
            summary_rows.append((f"{src_pill('live')}     Started at", f'<code>{ms.get("startedAt", "?")}</code>'))
            summary_rows.append((f"{src_pill('live')}     Triggered by puck", bool_pill(bool(ms.get("triggeredByPuck")))))
        else:
            summary_rows.append((f"{src_pill('live')} 💻 Mac session active", pill("NO", "muted")))
        if cb.get("present"):
            summary_rows.append((f"{src_pill('live')} 💻 Current block", f'<code>{cb.get("type")} — {cb.get("title")}</code>'))
        else:
            summary_rows.append((f"{src_pill('live')} 💻 Current block", pill("NONE", "muted")))
    else:
        summary_rows.append((f"{src_pill('inferred')} 💻 Mac focus engaged", status_pill(state["focus_state"])))
        if state.get("focus_last_event"):
            ev = dt.datetime.fromisoformat(state["focus_last_event"])
            summary_rows.append((f"{src_pill('inferred')}     Last event", f'{human_delta(ev)}'))

    summary_rows.append(("🔗 Match", sync_pill))

    summary_html = '<table class="kv">' + "".join(
        f'<tr><td>{k}</td><td>{v}</td></tr>' for k, v in summary_rows
    ) + "</table>"

    # ----- Connection -----
    proc_html = ""
    if state["processes"]:
        for pid, lstart, cmd, is_relay in state["processes"]:
            label = "(relay)" if is_relay else "(primary)"
            proc_html += f'<tr><td>PID {pid} {label}</td><td>started <code>{lstart}</code></td></tr>'
    else:
        proc_html = '<tr><td colspan=2><em>No Intentional process running</em></td></tr>'

    conn_rows = [
        (f"{src_pill('system')} Mac process", "(see below)"),
    ]
    if live_fresh:
        conn_rows.append((f"{src_pill('live')} Mac WebSocket", bool_pill(ws_connected, "CONNECTED", "DISCONNECTED")))
        conn_rows.append((f"{src_pill('live')} State dump fresh", f'<code>{int(state["mac_live_age_seconds"])}s ago</code>'))
    else:
        conn_rows.append((f"{src_pill('inferred')} Mac WebSocket", status_pill(state["ws_state"])))
        if state.get("ws_last_event"):
            ev = dt.datetime.fromisoformat(state["ws_last_event"])
            conn_rows.append((f"{src_pill('inferred')}     WS last event", f'{human_delta(ev)}'))
        conn_rows.append((f"{src_pill('system')} State dump fresh", pill("MISSING — install latest PKG for ground-truth state", "warn")))
    conn_rows.append((f"{src_pill('api')} Backend reachable", bool_pill(backend_reachable)))
    auth_label = "200 ✓" if backend_auth_ok else f"{backend_http} ✗ (token rejected)" if backend_http == 401 else f"{backend_http}"
    conn_rows.append((f"{src_pill('api')}     /focus/active HTTP", f'<code>{auth_label}</code>'))
    if me.get("account_id"):
        conn_rows.append((f"{src_pill('api')} Account", f'<code>{me["email"]}</code>'))
        conn_rows.append((f"{src_pill('api')}     Account ID", f'<code>{me["account_id"][:12]}…</code>'))
        conn_rows.append((f"{src_pill('api')}     Devices", f'<code>{len(me.get("devices", []))} registered</code>'))

    # Add live enforcement detail when present
    if live_fresh:
        enf = live.get("enforcement", {})
        conn_rows.append((f"{src_pill('live')} Blocked domains", f'<code>{enf.get("blocked_domains_count", 0)}</code>'))
        conn_rows.append((f"{src_pill('live')} Blocked apps", f'<code>{enf.get("blocked_apps_count", 0)}</code>'))
        conn_rows.append((f"{src_pill('live')} Distracting bundle IDs", f'<code>{enf.get("distracting_app_bundle_ids_count", 0)}</code>'))

    conn_html = '<table class="kv">' + "".join(
        f'<tr><td>{k}</td><td>{v}</td></tr>' for k, v in conn_rows
    ) + "</table>"
    conn_html += "<h3>Processes</h3><table class='kv'>" + proc_html + "</table>"

    # ----- Tokens -----
    tok_rows = [
        ("Access token", status_pill(state["access_token_status"])),
    ]
    if state["access_token_exp"]:
        exp = dt.datetime.fromisoformat(state["access_token_exp"])
        tok_rows.append(("    Expires", f'{human_delta(exp)}  <span class="muted">({exp.isoformat()})</span>'))
    tok_rows.append(("Refresh token", bool_pill(state["refresh_token_present"], "present", "missing")))
    tok_html = '<table class="kv">' + "".join(
        f'<tr><td>{k}</td><td>{v}</td></tr>' for k, v in tok_rows
    ) + "</table>"

    # ----- Boundary checks -----
    boundaries = []
    boundaries.append((
        "iPhone → Backend",
        "Phone signal reached backend (any active session within last hour)",
        iphone_active,
        "Tap puck on iPhone, retry. If still red: iPhone may be offline or signed out, "
        "or backend rejected the POST.",
    ))
    boundaries.append((
        "Backend → Mac WS",
        "Mac is subscribed and able to receive backend pushes",
        ws_connected,
        "Restart Mac app. Watchdog will relaunch with the latest token. "
        "If still red: token may be expired (check tokens above) or backend down.",
    ))
    enforcement_ok = (mac_engaged and iphone_active) or (not iphone_active and not mac_engaged and not mac_phantom)
    boundaries.append((
        "Mac handler → enforcement",
        "Mac correctly engages/disengages based on backend state",
        enforcement_ok,
        "If Mac thinks it's in a session but iPhone isn't: phantom state. "
        "Restart the Mac app. If still wrong: scrub focusSessionManager state to disk.",
    ))
    boundary_html = "<table class='kv'>"
    for name, desc, ok, hint in boundaries:
        emoji = "🟢" if ok else "🔴"
        boundary_html += (
            f'<tr><td><b>{emoji} {name}</b><br><span class="muted">{desc}</span></td>'
            f'<td>{bool_pill(ok)}<br><span class="muted small">{hint if not ok else ""}</span></td></tr>'
        )
    boundary_html += "</table>"

    # ----- Log tails -----
    def fmt_log(lines: list[str]) -> str:
        if not lines:
            return '<p class="muted"><em>No matching log lines</em></p>'
        return '<pre class="log">' + "\n".join(
            l.replace("<", "&lt;").replace(">", "&gt;") for l in lines
        ) + '</pre>'

    signals_html = fmt_log(state["recent_signals"])
    auth_html = fmt_log(state["recent_auth"])
    ws_log_html = fmt_log(state["ws_log"])
    focus_log_html = fmt_log(state["focus_log"])

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Intentional · Focus state debug · {NOW.isoformat()}</title>
<style>
  :root {{
    --bg: #0a0c0a;
    --card: rgba(255,255,255,0.04);
    --border: rgba(255,255,255,0.08);
    --text: #f7f8f8;
    --muted: rgba(255,255,255,0.55);
    --dim: rgba(255,255,255,0.36);
    --green: #6FB58E;
    --red: #D45050;
    --amber: #E5A063;
    --coral: #E87461;
    --gold: #F0B060;
    --grad: linear-gradient(135deg, var(--coral), var(--gold));
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; padding: 0; background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro", system-ui, sans-serif; line-height: 1.5; }}
  .wrap {{ max-width: 1100px; margin: 0 auto; padding: 32px 28px 96px; }}
  header {{ margin-bottom: 28px; display: flex; align-items: center; justify-content: space-between; gap: 24px; flex-wrap: wrap; }}
  header h1 {{ font-size: 24px; margin: 0; letter-spacing: -0.4px; }}
  header h1 .accent {{ background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent; }}
  header .ts {{ color: var(--dim); font-family: "SF Mono", monospace; font-size: 12.5px; }}
  header .refresh-hint {{ color: var(--muted); font-size: 13px; }}
  header .refresh-hint code {{ background: rgba(255,255,255,0.06); border: 1px solid var(--border); padding: 2px 8px; border-radius: 6px; color: var(--gold); font-size: 12px; }}
  .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }}
  .grid.full {{ grid-template-columns: 1fr; }}
  .card {{
    background: var(--card); border: 1px solid var(--border); border-radius: 12px;
    padding: 20px 22px; margin-bottom: 14px;
  }}
  .card h2 {{ font-size: 15px; margin: 0 0 14px; letter-spacing: 0.2px; display: flex; align-items: center; gap: 8px; }}
  .card h3 {{ font-size: 12px; text-transform: uppercase; letter-spacing: 1px; color: var(--dim); margin: 18px 0 8px; }}
  .ico {{ font-size: 18px; }}
  table.kv {{ width: 100%; border-collapse: collapse; font-size: 13.5px; }}
  table.kv td {{ padding: 8px 10px 8px 0; vertical-align: top; border-bottom: 1px solid var(--border); }}
  table.kv tr:last-child td {{ border-bottom: none; }}
  table.kv td:first-child {{ color: var(--muted); white-space: nowrap; }}
  code {{ font-family: "SF Mono", Menlo, monospace; font-size: 12px; background: rgba(255,255,255,0.05);
    border: 1px solid var(--border); padding: 1px 6px; border-radius: 5px; }}
  .pill {{ display: inline-flex; align-items: center; padding: 3px 10px; border-radius: 999px; font-size: 11px;
    font-weight: 600; letter-spacing: 0.4px; text-transform: uppercase; }}
  .pill-ok    {{ background: rgba(111,181,142,0.12); color: var(--green); border: 1px solid rgba(111,181,142,0.32); }}
  .pill-bad   {{ background: rgba(212,80,80,0.12);   color: var(--red);   border: 1px solid rgba(212,80,80,0.32); }}
  .pill-warn  {{ background: rgba(229,160,99,0.12);  color: var(--amber); border: 1px solid rgba(229,160,99,0.32); }}
  .pill-muted {{ background: rgba(255,255,255,0.04); color: var(--muted); border: 1px solid var(--border); }}
  .src {{ display: inline-block; font-size: 9px; font-weight: 700; letter-spacing: 0.6px; padding: 1px 5px; border-radius: 3px; margin-right: 6px; vertical-align: 1px; }}
  .src-live {{ background: rgba(111,181,142,0.15); color: var(--green); }}
  .src-inferred {{ background: rgba(229,160,99,0.15); color: var(--amber); }}
  .muted {{ color: var(--muted); }}
  .small {{ font-size: 11.5px; }}
  pre.log {{ background: rgba(0,0,0,0.45); border: 1px solid var(--border); border-radius: 8px; padding: 12px;
    font-size: 11.5px; line-height: 1.55; max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-word; }}
</style>
</head>
<body>
<div class="wrap">

<header>
  <div>
    <h1>Intentional · Focus <span class="accent">debug</span></h1>
    <div class="muted">Live state of cross-device focus across iPhone, backend, and Mac.</div>
  </div>
  <div>
    <div class="ts">Generated {NOW.isoformat()}</div>
    <div class="refresh-hint">Re-run <code>python3 scripts/focus-debug.py</code> to refresh.</div>
  </div>
</header>

<div class="grid full">
  {section("Cross-device session state", "🎯", summary_html)}
</div>

<div class="grid full">
  {section("Boundary checks", "🛤️", boundary_html)}
</div>

<div class="grid">
  {section("Connection state", "🔌", conn_html)}
  {section("Tokens", "🔑", tok_html)}
</div>

<div class="grid">
  {section("Recent focus signals (Mac WS)", "📨", signals_html)}
  {section("Recent auth/refresh events", "🔄", auth_html)}
</div>

<div class="grid">
  {section("WebSocket log tail", "🌐", ws_log_html)}
  {section("Focus session log tail", "📋", focus_log_html)}
</div>

<p class="muted small">
  <strong>Each value is tagged by source:</strong>
  <span class="src src-live">LIVE</span> = ground truth from Mac state dump (read just now);
  <span class="src src-live">API</span> = ground truth from backend HTTPS call;
  <span class="src src-live">SYS</span> = ground truth from macOS system commands;
  <span class="src src-inferred">LOG</span> = inferred from log scraping (latest matching event, may be stale).
  <br><br>
  State dump: <code>{state["state_path"]}</code> (refreshed every 5s by the Mac app)<br>
  Source log: <code>{state["log_path"]}</code><br>
  Backend: <code>{BACKEND}</code>
</p>

</div>
</body>
</html>
"""


def main():
    state = gather()
    html = render(state)
    with open(HTML_OUT, "w") as f:
        f.write(html)
    print(f"Wrote {HTML_OUT}")
    if "--no-open" not in sys.argv:
        subprocess.run(["open", HTML_OUT])


if __name__ == "__main__":
    main()
