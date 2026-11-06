import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import cs2_update_watch as watch


NOW = datetime(2026, 11, 6, 8, tzinfo=timezone.utc)
CFG = "Fixed +exec ignoring profile CFG files at startup."
VIDEO = "Changed how fullscreen is saved in cs2_video.txt."
UNRELATED = r"""
\[ MAP SCRIPTING ]
Added console commands to the workshop API.
\[ GAMEPLAY ]
Added pet chicken names in freeze time.
Fixed spectator crosshair settings in demo playback.
"""


def update(notes, *, posted=NOW, edited=NOW):
    return watch.Update("123", posted, edited, "https://example.org/123", notes)


class WatchTests(unittest.TestCase):
    def test_relevant_and_unrelated_notes(self):
        self.assertEqual(list(watch.relevant_notes(UNRELATED)), [])
        notes = UNRELATED + f"\n[ MISC ]\n{CFG}\n{VIDEO}"
        self.assertEqual([line for line, _ in watch.relevant_notes(notes)], [CFG, VIDEO])

    def test_official_feeds_share_announcement_id(self):
        rss = b"""<rss><channel><item>
          <link>https://steamcommunity.com/games/CSGO/announcements/detail/123</link>
          <pubDate>Fri, 06 Nov 2026 08:00:00 +0000</pubDate>
          <description>&lt;p&gt;[ MISC ]&lt;/p&gt;&lt;li&gt;Original text&lt;/li&gt;</description>
        </item></channel></rss>"""
        events = json.dumps({"success": 1, "events": [{
            "appid": 730, "gid": "456", "announcement_body": {
                "gid": "123", "posttime": int(NOW.timestamp()),
                "updatetime": int(NOW.timestamp()), "body": f"[p][ MISC ][/p][list][*][p]{CFG}[/p][/list]",
            },
        }]}).encode()
        empty = b'{"success":1,"events":[]}'
        with patch.object(watch, "fetch", side_effect=[rss, events, empty]):
            updates = list(watch.get_updates(NOW))
        self.assertEqual(len(updates), 1)
        self.assertIn(CFG, updates[0].notes)
        self.assertEqual(updates[0].url,
                         "https://steamcommunity.com/games/CSGO/announcements/detail/123")

    def test_edit_only_alerts_on_new_relevant_text(self):
        old = NOW - timedelta(days=2)
        since = NOW - timedelta(days=1)
        original = update(CFG, posted=old, edited=old)
        seen = set()
        self.assertEqual(list(watch.pending_alerts([original], since, seen)), [])
        watch.remember_notes([original], seen)
        edited = update(f"{CFG}\n{VIDEO}", posted=old)
        alerts = list(watch.pending_alerts([edited], since, seen))
        self.assertEqual([item[1] for item in alerts], [VIDEO])
        seen.add(alerts[0][3])
        self.assertEqual(list(watch.pending_alerts([edited], since, seen)), [])

    def test_smtp_failure_does_not_advance_checkpoint(self):
        state = {"checked_at": (NOW - timedelta(days=1)).isoformat(), "seen": []}
        with (patch.object(watch, "GitState") as store,
              patch.object(watch, "get_updates", return_value=[update(CFG)]),
              patch.object(watch, "send_email", side_effect=OSError("unavailable"))):
            store.return_value.load.return_value = state
            with self.assertRaises(OSError):
                watch.run("live")
            store.return_value.save.assert_not_called()

    def test_live_run_records_delivery_and_replay_stays_silent(self):
        now = datetime.now(timezone.utc)
        announcement = update(CFG, posted=now, edited=now)
        with (patch.object(watch, "GitState") as store,
              patch.object(watch, "get_updates", return_value=[announcement]),
              patch.object(watch, "send_email") as send):
            state = {}

            def save(checked_at, seen):
                state.update(checked_at=checked_at.isoformat(), seen=list(seen))

            store.return_value.load.return_value = state
            store.return_value.save.side_effect = save
            watch.run("live")
            watch.run("live")
            send.assert_called_once()
            self.assertIn(CFG, send.call_args.args[1])
            self.assertIn("Café PC testing checklist", send.call_args.args[1])

    def test_git_state_round_trip_uses_only_state_branch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            remote = root / "remote.git"
            checkout = root / "checkout"
            subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
            subprocess.run(["git", "init", "-q", checkout], check=True)
            subprocess.run(["git", "-C", checkout, "remote", "add", "origin", remote], check=True)
            previous = Path.cwd()
            try:
                os.chdir(checkout)
                store = watch.GitState()
                self.assertEqual(store.load(), {})
                store.save(NOW, {"test"})
                store = watch.GitState()
                self.assertEqual(store.load(), {"checked_at": NOW.isoformat(), "seen": ["test"]})
                store.save(NOW, {"test", "another"})
                self.assertEqual(watch.GitState().load()["seen"], ["another", "test"])
                refs = watch.git("ls-remote", "--heads", "origin").stdout.splitlines()
                self.assertEqual([line.split()[1] for line in refs], [watch.STATE_REF])
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
