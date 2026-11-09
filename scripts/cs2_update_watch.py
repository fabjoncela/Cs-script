"""Watch official CS2 and NVIDIA updates for changes that affect CafeLauncher."""
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
GEFORCE_RSS = "https://www.nvidia.com/content/rss/geforce/news/index.php"
NVAPI_COMMITS = "https://api.github.com/repos/NVIDIA/nvapi/commits?per_page=30"
NPI_RELEASES = "https://api.github.com/repos/Orbmu2k/nvidiaProfileInspector/releases?per_page=20"
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
    source: str = "CS2"


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
    headers = {"User-Agent": "CafeLauncher-Update-Watch/1.0", "Accept": "application/json, application/atom+xml, application/rss+xml, text/xml, text/html"}
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


NVIDIA_RULES = (
    (r"\b(?:NVAPI|NVIDIA API|driver profile(?: database| API)?|DRS|profile setting definitions?|"
     r"setting IDs|setting values|custom setting names|CustomSettingNames\.xml|Reference\.xml)\b",
     "NVIDIA's driver-profile API or setting definitions may have changed; the launcher's DRS read/write or compatibility checks may need adjustment.",
     ("Apply XProfile Mode and confirm each NVIDIA setting is reported as APPLIED or an expected fallback in LIVE LOGS.",
      "Reopen NVIDIA Control Panel or Profile Inspector and confirm the global and cs2.exe profile values persisted.")),
    (r"\b(?:display modes?|resolution enumeration|refresh rates?|GPU scaling|scaling mode|display scaling)\b",
     "The NVIDIA display-mode or scaling path may have changed; XProfile resolution, refresh, or scaling application may need adjustment.",
     ("Apply a profile and verify its resolution, highest refresh rate, and selected scaling mode.",
      "Check the NVIDIA setting result in LIVE LOGS and confirm the active display mode in Windows.")),
    (r"\b(?:digital vibrance|vibrance|hue angle|color controls?)\b",
     "NVIDIA color-control behavior may have changed; XProfile vibrance or hue application may need adjustment.",
     ("Apply profiles with different vibrance and hue values and confirm the reported values and visible result.")),
    (r"\b(?:low latency|PhysX|G-SYNC|GSync|performance profile|power management mode)\b",
     "A driver setting used by XProfile Mode may have changed or regressed.",
     ("Apply XProfile Mode and verify CS2 Low Latency, PhysX, power, and G-SYNC results in LIVE LOGS and the driver profile.")),
)
NVIDIA_RELEVANCE = re.compile(
    r"\b(?:add(?:ed|s)?|allow(?:ed|s)?|apply|appl(?:ied|ies)|change[ds]?|deprecat(?:ed|es)|"
    r"disabl(?:ed|es)|enabl(?:ed|es)|fix(?:ed|es)?|introduc(?:ed|es)|limit(?:ed|s)?|"
    r"new|no longer|not|overrid\w+|persist\w*|regression|remov(?:ed|es)|requir\w+|"
    r"reset\w*|support\w*|update[ds]?|writ(?:e|es|ten)|fail(?:ed|s|ure)?|"
    r"issue|problem|bug|incorrect|unavailable|broken|lost|crash|may|SDK|release notes?)\b", re.I
)
DRIVER_TITLE = re.compile(r"\b(?:game ready|geforce|display) driver\b|\bdriver release notes\b", re.I)


def nvidia_rss_updates(data):
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if not items:
        raise ValueError("NVIDIA GeForce RSS returned no announcements")
    updates = []
    for item in items:
        title = item.findtext("title", "").strip()
        url = item.findtext("link", "").strip()
        if not title or not url.startswith("https://www.nvidia.com/"):
            continue
        raw_date = item.findtext("pubDate", "").strip()
        try:
            posted = parsedate_to_datetime(raw_date)
        except (TypeError, ValueError):
            # NVIDIA's GeForce RSS currently publishes calendar dates rather
            # than RFC 822 timestamps; treat the date as a day-level timestamp.
            posted = datetime.strptime(raw_date, "%B %d, %Y").replace(tzinfo=timezone.utc)
        parser = NoteHTML()
        parser.feed(item.findtext("description", ""))
        notes = title + "\n" + "".join(parser.parts)
        updates.append(Update("geforce:" + url.rstrip("/").rsplit("/", 1)[-1], posted, posted,
                              url, notes, "NVIDIA driver/news"))
    if not updates:
        raise ValueError("NVIDIA GeForce RSS had no valid NVIDIA announcements")
    return updates


def nvidia_api_updates(data, since):
    payload = json.loads(data)
    if not isinstance(payload, list):
        raise ValueError("NVIDIA NVAPI commits returned an unexpected response")
    updates = []
    for commit in payload:
        meta = commit.get("commit", {})
        message = str(meta.get("message", "")).splitlines()[0].strip()
        timestamp = meta.get("committer", {}).get("date")
        sha = str(commit.get("sha", ""))
        if not message or not timestamp or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("NVIDIA NVAPI commit data was incomplete")
        posted = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if posted < since - REVIEW_WINDOW:
            continue
        # The official SDK commit stream is specifically NVAPI, so each SDK
        # release is worth reviewing even when its short commit title is sparse.
        if not re.search(r"\b(?:SDK|NVAPI|release notes?)\b", message, re.I):
            continue
        updates.append(Update("nvapi:" + sha, posted, posted,
                              str(commit.get("html_url", "https://github.com/NVIDIA/nvapi")),
                              message, "NVIDIA NVAPI"))
    return updates


def npi_release_updates(data, since):
    payload = json.loads(data)
    if not isinstance(payload, list):
        raise ValueError("NVIDIA Profile Inspector releases returned an unexpected response")
    updates = []
    for release in payload:
        tag = str(release.get("tag_name", "")).strip()
        title = str(release.get("name") or tag).strip()
        body = str(release.get("body") or "")
        url = str(release.get("html_url", ""))
        timestamp = release.get("published_at") or release.get("created_at")
        if not tag or not url.startswith("https://github.com/Orbmu2k/nvidiaProfileInspector/") or not timestamp:
            raise ValueError("NVIDIA Profile Inspector release data was incomplete")
        posted = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if posted < since - REVIEW_WINDOW:
            continue
        updates.append(Update("npi:" + tag, posted, posted, url, title + "\n" + body,
                              "NVIDIA Profile Inspector"))
    return updates


def get_nvidia_updates(since):
    """Read NVIDIA driver news plus the official NVAPI and upstream NPI streams."""
    updates = nvidia_rss_updates(fetch(GEFORCE_RSS))
    # NVIDIA's GeForce feed includes general articles; only fetch the detail
    # page for driver announcements, then relevance-filter its release notes.
    detailed = []
    for update in updates:
        if max(update.posted, update.edited) >= since - REVIEW_WINDOW and DRIVER_TITLE.search(update.notes):
            parser = NoteHTML()
            parser.feed(fetch(update.url).decode("utf-8", errors="replace"))
            update.notes += "\n" + "".join(parser.parts)
        detailed.append(update)
    api_data = json.loads(fetch(NVAPI_COMMITS))
    if not isinstance(api_data, list):
        raise ValueError("NVIDIA NVAPI commits returned an unexpected response")
    releases_data = fetch(NPI_RELEASES)
    # Keep one 14-day review window for edited/delayed announcements and use
    # stable upstream IDs for deduplication across runs.
    result = detailed + nvidia_api_updates(json.dumps(api_data).encode("utf-8"), since)
    result += npi_release_updates(releases_data, since)
    return result


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


def relevant_nvidia_notes(notes, source):
    for raw in notes.splitlines():
        line = " ".join(raw.split()).lstrip("•*- ")
        if not line or not NVIDIA_RELEVANCE.search(line):
            continue
        matches = [rule for rule in NVIDIA_RULES if re.search(rule[0], line, re.I)]
        if source == "NVIDIA NVAPI" and not matches:
            # This source is the official NVAPI SDK change stream; its releases
            # are intentionally reviewed even when the title omits API terms.
            matches = [NVIDIA_RULES[0]]
        if source == "NVIDIA Profile Inspector" and re.search(
                r"\b(?:CustomSettingNames|Reference\.xml|driver data|profile setting|DRS|NVAPI)\b", line, re.I):
            matches = list(dict.fromkeys(matches + [NVIDIA_RULES[0]]))
        if matches:
            yield line, matches


def update_relevance(update):
    if update.source == "CS2":
        return relevant_notes(update.notes)
    return relevant_nvidia_notes(update.notes, update.source)


def pending_alerts(updates, since, sent):
    for update in sorted(updates, key=lambda item: item.posted):
        # NVIDIA's GeForce feed has date-only pubDate values. Compare those by
        # calendar day so an article published after the prior run that day
        # is not missed just because its synthetic time is midnight UTC.
        if update.source == "NVIDIA driver/news":
            outside_window = max(update.posted, update.edited).date() < since.astimezone(timezone.utc).date()
        else:
            outside_window = max(update.posted, update.edited) < since
        if outside_window:
            continue
        for line, rules in update_relevance(update):
            digest = hashlib.sha256(line.casefold().encode()).hexdigest()
            alert_id = (f"{update.id}:{digest}" if update.source == "CS2"
                        else f"{update.source}:{update.id}:{digest}")
            if alert_id not in sent:
                yield update, line, rules, alert_id


def remember_notes(updates, sent):
    # Save the baseline for recent notes that were already outside the alert
    # window. If Valve edits one later, only a new relevant line can alert.
    for update in updates:
        for line, _ in update_relevance(update):
            digest = hashlib.sha256(line.casefold().encode()).hexdigest()
            alert_id = (f"{update.id}:{digest}" if update.source == "CS2"
                        else f"{update.source}:{update.id}:{digest}")
            sent.add(alert_id)


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
    publisher = "Valve CS2" if update.source == "CS2" else update.source
    lines = [f"{publisher} update date: {update.posted.astimezone(local_time):%Y-%m-%d}",
             f"Source and details: {update.url}"]
    if update.edited > update.posted:
        lines.append(f"Last edited: {update.edited.astimezone(local_time):%Y-%m-%d}")
    checks = {}
    for note, rules in findings:
        lines.extend(("", f"Reported change: {note}", "Potential CafeLauncher impact:"))
        for _, impact, tests in rules:
            lines.append(f"- {impact}")
            checks.update(dict.fromkeys(tests))
    checklist = "XProfile Mode testing checklist:" if update.source != "CS2" else "Café PC testing checklist:"
    lines.extend(("", checklist, *(f"- {check}" for check in checks)))
    return "\n".join(lines)


def run(mode):
    if mode == "test-email":
        send_email("CafeLauncher compatibility watch SMTP test",
                   "This test confirms that GitHub Actions can send CafeLauncher update alerts.")
        return
    now = datetime.now(timezone.utc)
    store = GitState()
    state = store.load()
    since = datetime.fromisoformat(state["checked_at"]) if state else now - timedelta(hours=24)
    seen = set(state.get("seen", []))
    updates = list(get_updates(since))
    updates.extend(get_nvidia_updates(since))
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
            subject = ("CS2 update may affect CafeLauncher" if update.source == "CS2"
                       else f"{update.source} update may affect CafeLauncher")
            send_email(subject, body)
            seen.update(alert_ids)
            store.save(since, seen)
    if mode == "live":
        remember_notes(updates, seen)
        store.save(now, seen)
    print(f"Checked Valve CS2 and NVIDIA sources: {len(updates)} announcements/releases, {len(alerts)} qualifying updates.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("dry-run", "test-email", "live"))
    try:
        run(parser.parse_args().mode)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError, ET.ParseError) as error:
        # SMTP replies may contain recipient addresses or provider details.
        if isinstance(error, smtplib.SMTPException):
            parser.exit(1, f"Compatibility update watch failed: {type(error).__name__}\n")
        parser.exit(1, f"Compatibility update watch failed: {error}\n")
