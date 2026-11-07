"""Watch official CS2 notes for changes that affect CafeLauncher."""
import argparse
import hashlib
import json
import os
import re
import smtplib
import ssl
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import parsedate_to_datetime
from html import unescape
from html.parser import HTMLParser
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

EVENTS = "https://store.steampowered.com/events/ajaxgetpartnereventspageable/"
RSS = "https://steamcommunity.com/games/CSGO/rss/"
STATE_REF = "refs/heads/cs2-watch-state"
REVIEW_WINDOW = timedelta(days=14)

RULES = (
    (r"\b(?:exec|autoexec|cfg files?|cfg (?:paths?|directories|folders?)|"
     r"config(?:uration)? files?|load order)\b|\.cfg\b",
     "Play + Exec or profile CFG installation may need a path, argument, or execution-order adjustment.",
     ("Run Play + Exec with CS2 closed and verify the baseline runs before the profile CFG.",
      "Switch profiles and verify the second profile applies without stale binds.")),
    (r"\b(?:key[ -]?bind(?:ing)?s?|binds?|unbind(?:all)?|user_keys\w*|"
     r"input bind(?:ing)?s?|multi[- ]action binds?|switchhands|toggleconsole|player_ping|"
     r"slot(?:6|7|8|10))\b|(?<!\w)\+(?:jump|reload|voicerecord|lookatweapon)\b",
     "Profile binds or the baseline reset may stop applying or persisting as expected.",
     ("Apply a profile that uses the affected bind and verify the key in a practice session.",
      "Switch profiles and restart CS2 to check for stale or reset binds.")),
    (r"\b(?:cl_crosshair\w*|cl_ironsight\w*|crosshair (?:settings?|styles?|share codes?|"
     r"codes?|options?|colors?|outlines?|gaps?|sizes?)|crosshair)\b",
     "Profile crosshair settings, capture, or share-code import may need adjustment.",
     ("Run a profile CFG with the affected crosshair setting and check its value and appearance.",
      "If capture or share codes are affected, compare the imported values with the in-game settings.")),
    (r"\b(?:cs2_video\.txt|videocfg_\w+|video (?:config(?:uration)?|settings?|options?)|"
     r"graphics (?:settings?|options?|presets?)|aspect ratio|display mode|refresh rate|"
     r"full[ -]?screen|windowed|screen resolution|display resolution|vertical sync|v[ -]?sync|"
     r"frame pacing|anti[- ]aliasing|msaa|cmaa\w*|nvidia reflex|fidelityfx|fsr|"
     r"shadow quality|dynamic shadows|ambient occlusion|texture filtering|"
     r"(?:shader|particle|texture|model) (?:detail|quality)|high dynamic range|hdr|"
     r"player visibility|boost player contrast|r_player_visibility_mode)\b"
     r"|\bsetting\.[a-z0-9_]+\b",
     "Apply Graphics or Capture CS2 may need a new file path, key, value mapping, or startup check.",
     ("Close CS2 and apply the affected setting on the active Steam account.",
      "Compare the saved file and in-game value after launch and check an unrelated key.")),
    (r"\b(?:launch (?:options?|arguments?|parameters?|flags?)|"
     r"(?:startup|command[- ]line) (?:arguments?|options?|parameters?|flags?)|"
     r"steam (?:launch|startup|cloud|userdata|libraries|library folders?|install paths?|"
     r"accounts?|account switching)|steam://(?:run|rungameid)|"
     r"libraryfolders\.vdf|appmanifest_730\.acf|cs2\.exe|"
     r"(?:cs2|game) (?:installation|install (?:paths?|folders?|locations?)|executable)|"
     r"(?:active|signed[- ]in) steam (?:user|account)|userdata[/\\])",
     "Steam may pass different launch arguments or load different account settings in Play + Exec.",
     ("Test Play + Exec with Steam closed and already running.",
      "If account behavior changed, switch Steam accounts and verify the settings load for the active one.")),
    (r"\b(?:console (?:commands?|variables?)|developer console|cvars?|convars?|"
     r"cs2_user_convars\w*|con_enable|r_low_latency|fps_max|zoom_sensitivity_ratio|"
     r"cl_radar_\w+|cl_hud_radar_scale|cl_teamcounter_playercount_instead_of_avatars|"
     r"viewmodel_\w+|cl_mute_enemy_team|raw (?:mouse )?input|mouse acceleration|"
     r"(?:mouse |zoom )?sensitivity)\b",
     "An affected profile command may be rejected, interpreted differently, or overwritten.",
     ("Execute the affected command and check for errors or changed values in the console.",
      "Run the profile CFG and verify the expected behavior in a practice session.")),
    (r"\b(?:isteamugc\w*|steam_api64\.dll|steamworks (?:runtime|sdk|api)|"
     r"get(?:num)?subscribeditems|appworkshop_730\.acf|"
     r"workshop (?:subscriptions?|manifests?|install(?:ation)? (?:paths?|folders?|directories)|"
     r"downloads?|content (?:paths?|folders?|directories))|"
     r"subscribed (?:workshop )?items)\b",
     "Workshop Cleanup may need to adapt how it checks subscriptions, manifests, or installed items.",
     ("Run a scan with a signed-in Steam account and compare subscribed items with Steam.",
      "Verify unknown or downloading items stay protected and cancel before removing files.")),
)
CHANGE = re.compile(
    r"\b(?:add(?:ed|s)?|allow(?:ed|s)?|apply|appl(?:ied|ies)|accept(?:ed|s)?|"
    r"chang(?:e|ed|es)|deprecat(?:ed|es)|disabl(?:ed|es)|enabl(?:ed|es)|"
    r"execut(?:e|ed|es|ion)|fix(?:ed|es)?|ignor(?:e|ed|es)|limit(?:ed|s)?|"
    r"load(?:ed|s)?|mov(?:ed|es)|now|overrid\w+|persist\w*|reject\w*|"
    r"remov(?:ed|es)|renam(?:ed|es)|replac(?:ed|es)|requir\w+|reset\w*|"
    r"restrict\w*|brok\w*|prevent\w*|no longer|sav(?:ed|es)|support\w*|us(?:ed|es)|writ\w*)\b", re.I
)
SECTION = re.compile(r"\\*\s*\[\s*([^\[\]]+)\s*\]")
UNRELATED = re.compile(r"\b(?:spectat\w*|demo playback|observer|inventory|sticker|cosmetic|chicken)\b", re.I)
BB_BREAK = re.compile(r"\[(?:/?(?:p|list|olist|h[1-6])|\*)\]", re.I)
BB_INLINE = re.compile(r"\[/?(?:b|i|u|s|code|url(?:=[^\]]*)?)\]", re.I)


@dataclass
class Update:
    id: str
    posted: datetime
    edited: datetime
    url: str
    notes: str


class NoteHTML(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in {"br", "li", "p", "div", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        self.handle_starttag(tag, ())

    def handle_data(self, data):
        self.parts.append(data)


def fetch(url, *, origin=None):
    headers = {"User-Agent": "CafeLauncher-CS2-Update-Watch/1.0"}
    if origin:
        headers["Origin"] = origin
    with urlopen(Request(url, headers=headers), timeout=30) as response:
        return response.read()


def steam_rss(data):
    items = ET.fromstring(data).findall("./channel/item")
    if not items:
        raise ValueError("Steam RSS returned no announcements")
    for item in items:
        url = item.findtext("link", "").strip()
        match = re.fullmatch(r"https://steamcommunity\.com/games/CSGO/announcements/detail/(\d+)", url)
        if not match:
            raise ValueError("Unexpected Steam RSS announcement link")
        posted = parsedate_to_datetime(item.findtext("pubDate"))
        parser = NoteHTML()
        parser.feed(item.findtext("description", ""))
        yield Update(match[1], posted, posted, url, "".join(parser.parts))


def valve_events(data):
    payload = json.loads(data)
    if payload["success"] != 1 or not isinstance(payload["events"], list):
        raise ValueError("Valve release-note feed returned an unexpected response")
    for event in payload["events"]:
        announcement = event.get("announcement_body")
        if str(event["appid"]) != "730" or not announcement:
            continue
        if not all(str(value).isdigit() for value in (event["gid"], announcement["gid"])):
            raise ValueError("Unexpected Valve announcement ID")
        posted = datetime.fromtimestamp(announcement["posttime"], timezone.utc)
        edited = datetime.fromtimestamp(announcement["updatetime"], timezone.utc)
        body = unescape(BB_INLINE.sub("", BB_BREAK.sub("\n", announcement["body"])))
        yield Update(announcement["gid"], posted, edited,
                     f"https://steamcommunity.com/games/CSGO/announcements/detail/{announcement['gid']}", body)


def get_updates(since):
    # Valve's Counter-Strike site loads this Steam endpoint for its release notes.
    # The RSS feed uses the same announcement IDs and provides a second listing.
    rss_updates = {update.id: update for update in steam_rss(fetch(RSS))}
    event_updates = {}
    cutoff = since - REVIEW_WINDOW
    for offset in range(0, 500, 50):
        query = urlencode({"clan_accountid": 0, "appid": 730, "offset": offset,
                           "count": 50, "l": "english", "origin": "https://www.counter-strike.net"})
        page = list(valve_events(fetch(EVENTS + "?" + query, origin="https://www.counter-strike.net")))
        if not page:
            if not offset:
                raise ValueError("Valve release-note feed returned no announcements")
            break
        event_updates.update((update.id, update) for update in page)
        if min(update.posted for update in page) < cutoff:
            break
    else:
        raise ValueError("Could not fetch enough release-note history to cover the last successful check")
    print(f"Steam CS2 announcement RSS: {len(rss_updates)} announcements.")
    print(f"Valve CS2 release-note feed: {len(event_updates)} announcements.")
    return (rss_updates | event_updates).values()


def relevant_notes(notes):
    section = ""
    for raw in notes.splitlines():
        line = " ".join(raw.split()).lstrip("•*- ")
        if header := SECTION.fullmatch(line):
            section = header[1].lower()
            continue
        if UNRELATED.search(line) or not CHANGE.search(line):
            continue
        if section in {"workshop", "map scripting", "scripting"} or re.search(r"\bworkshop\b", line, re.I):
            rules = RULES[-1:]
        elif section in {"maps", "cosmetics", "armory"}:
            continue
        else:
            rules = RULES
        matches = [rule for rule in rules if re.search(rule[0], line, re.I)]
        if matches:
            yield line, matches


def pending_alerts(updates, since, sent):
    for update in sorted(updates, key=lambda item: item.posted):
        if max(update.posted, update.edited) < since:
            continue
        for line, rules in relevant_notes(update.notes):
            digest = hashlib.sha256(line.casefold().encode()).hexdigest()
            alert_id = f"{update.id}:{digest}"
            if alert_id not in sent:
                yield update, line, rules, alert_id


def remember_notes(updates, sent):
    # Save the baseline for recent notes that were already outside the alert
    # window. If Valve edits one later, only a new relevant line can alert.
    for update in updates:
        for line, _ in relevant_notes(update.notes):
            digest = hashlib.sha256(line.casefold().encode()).hexdigest()
            sent.add(f"{update.id}:{digest}")


def git(*args, input_text=None, check=True):
    result = subprocess.run(["git", *args],
                            input=None if input_text is None else input_text.encode("utf-8"),
                            stdout=subprocess.PIPE, check=check)
    result.stdout = result.stdout.decode("utf-8")
    return result


class GitState:
    def __init__(self):
        self.head = None

    def load(self):
        result = git("ls-remote", "--exit-code", "origin", STATE_REF, check=False)
        if result.returncode == 2:
            return {}
        result.check_returncode()
        git("fetch", "--no-tags", "origin", STATE_REF)
        self.head = git("rev-parse", "FETCH_HEAD").stdout.strip()
        return json.loads(git("show", f"{self.head}:state.json").stdout)

    def save(self, checked_at, seen):
        payload = json.dumps({"checked_at": checked_at.isoformat(), "seen": sorted(seen)}, indent=2)
        blob = git("hash-object", "-w", "--stdin", input_text=payload + "\n").stdout.strip()
        tree = git("mktree", input_text=f"100644 blob {blob}\tstate.json\n").stdout.strip()
        parents = ["-p", self.head] if self.head else []
        commit = git("-c", "user.name=CafeLauncher update watch",
                     "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                     "commit-tree", tree, *parents, "-m", "Record CS2 update watch state").stdout.strip()
        git("push", "origin", f"{commit}:{STATE_REF}")
        self.head = commit


def send_email(subject, body):
    names = ("SMTP_HOST", "SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_FROM", "SMTP_TO")
    settings = {name: os.environ.get(name) for name in names}
    if missing := [name for name in names if not settings[name]]:
        raise ValueError("Missing Actions secrets: " + ", ".join(missing))
    if settings["SMTP_PORT"] not in {"465", "587"}:
        raise ValueError("SMTP_PORT must be 465 (TLS) or 587 (STARTTLS)")
    port = int(settings["SMTP_PORT"])
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = settings["SMTP_FROM"]
    message["To"] = settings["SMTP_TO"]
    message.set_content(body)
    tls = ssl.create_default_context()
    client = smtplib.SMTP_SSL(settings["SMTP_HOST"], port, timeout=30, context=tls) if port == 465 else (
        smtplib.SMTP(settings["SMTP_HOST"], port, timeout=30)
    )
    try:
        if port == 587:
            client.starttls(context=tls)
        client.login(settings["SMTP_USERNAME"], settings["SMTP_PASSWORD"])
        client.send_message(message)
    finally:
        client.close()


def alert_body(update, findings):
    local_time = ZoneInfo("Europe/Tirane")
    lines = [f"Valve update date: {update.posted.astimezone(local_time):%Y-%m-%d}",
             f"Official release notes: {update.url}"]
    if update.edited > update.posted:
        lines.append(f"Last edited: {update.edited.astimezone(local_time):%Y-%m-%d}")
    checks = {}
    for note, rules in findings:
        lines.extend(("", f"Valve's change: {note}", "Potential CafeLauncher impact:"))
        for _, impact, tests in rules:
            lines.append(f"- {impact}")
            checks.update(dict.fromkeys(tests))
    lines.extend(("", "Café PC testing checklist:", *(f"- {check}" for check in checks)))
    return "\n".join(lines)


def run(mode):
    if mode == "test-email":
        send_email("CafeLauncher CS2 watch SMTP test",
                   "This test confirms that GitHub Actions can send CafeLauncher update alerts.")
        return
    now = datetime.now(timezone.utc)
    store = GitState()
    state = store.load()
    since = datetime.fromisoformat(state["checked_at"]) if state else now - timedelta(hours=24)
    seen = set(state.get("seen", []))
    updates = list(get_updates(since))
    # Keep the retry window stable even if the first live delivery fails.
    if mode == "live" and not state:
        store.save(since, seen)
    alerts = {}
    for update, note, rules, alert_id in pending_alerts(updates, since, seen):
        alerts.setdefault(update.id, (update, [], []))
        alerts[update.id][1].append((note, rules))
        alerts[update.id][2].append(alert_id)
    for update, findings, alert_ids in alerts.values():
        body = alert_body(update, findings)
        if mode == "dry-run":
            print(body)
        else:
            send_email("CS2 update may affect CafeLauncher", body)
            seen.update(alert_ids)
            store.save(since, seen)
    if mode == "live":
        remember_notes(updates, seen)
        store.save(now, seen)
    print(f"Checked {len(updates)} official announcements. {len(alerts)} qualifying updates.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("dry-run", "test-email", "live"))
    try:
        run(parser.parse_args().mode)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, ET.ParseError) as error:
        # SMTP replies may contain recipient addresses or provider details.
        if isinstance(error, smtplib.SMTPException):
            parser.exit(1, f"CS2 update watch failed: {type(error).__name__}\n")
        parser.exit(1, f"CS2 update watch failed: {error}\n")
