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

    def test_launcher_dependencies_named_in_patch_notes(self):
        notes = (
            "Fixed Steam libraryfolders.vdf loading.",
            "VSync no longer resets at launch.",
            "Fixed r_player_visibility_mode being ignored.",
            "Changed how +voicerecord works.",
            "Fixed cl_teamcounter_playercount_instead_of_avatars.",
            "[ WORKSHOP ]",
            "Added a workshop map.",
            "Changed ISteamUGC workshop subscription behavior.",
        )
        self.assertEqual([line for line, _ in watch.relevant_notes("\n".join(notes))],
                         [*notes[:5], notes[-1]])

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

    def test_nvidia_filter_keeps_driver_api_changes_and_ignores_broad_news(self):
        notes = """New GeForce feature spotlight for a game launch.
Updated NVAPI driver profile setting definitions.
Fixed an issue where GPU scaling mode was not persisted.
"""
        findings = list(watch.relevant_nvidia_notes(notes, "NVIDIA driver/news"))
        self.assertEqual([line for line, _ in findings], [
            "Updated NVAPI driver profile setting definitions.",
            "Fixed an issue where GPU scaling mode was not persisted.",
        ])

    def test_nvidia_geforce_feed_accepts_its_calendar_date_format(self):
        feed = b"""<rss><channel><item>
          <title>GeForce Game Ready Driver released</title>
          <link>https://www.nvidia.com/en-us/geforce/news/example-driver/</link>
          <pubDate>November 05, 2026</pubDate>
          <description>&lt;p&gt;Release notes available now.&lt;/p&gt;</description>
        </item></channel></rss>"""
        updates = watch.nvidia_rss_updates(feed)
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0].posted, datetime(2026, 11, 5, tzinfo=timezone.utc))
        self.assertEqual(updates[0].source, "NVIDIA driver/news")

    def test_official_nvapi_and_profile_inspector_updates_are_scoped(self):
        nvapi = [{
            "sha": "a" * 40,
            "html_url": "https://github.com/NVIDIA/nvapi/commit/" + "a" * 40,
            "commit": {"message": "R615-Developer SDK - Release notes", "committer": {"date": NOW.isoformat()}},
        }, {
            "sha": "b" * 40,
            "html_url": "https://github.com/NVIDIA/nvapi/commit/" + "b" * 40,
            "commit": {"message": "Update README.md", "committer": {"date": NOW.isoformat()}},
        }]
        updates = watch.nvidia_api_updates(json.dumps(nvapi).encode(), NOW)
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0].source, "NVIDIA NVAPI")
        self.assertTrue(list(watch.update_relevance(updates[0])))

        releases = [{
            "tag_name": "v3.0.2.3", "name": "v3.0.2.3",
            "body": "Update CustomSettingNames.xml with current profile setting values.",
            "html_url": "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/tag/v3.0.2.3",
            "published_at": NOW.isoformat(),
        }]
        npi_updates = watch.npi_release_updates(json.dumps(releases).encode(), NOW)
        self.assertEqual(len(npi_updates), 1)
        self.assertTrue(list(watch.update_relevance(npi_updates[0])))

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

    def test_date_only_nvidia_feed_does_not_miss_same_day_post(self):
        since = datetime(2026, 11, 5, 14, tzinfo=timezone.utc)
        announcement = watch.Update(
            "geforce:driver", datetime(2026, 11, 5, tzinfo=timezone.utc),
            datetime(2026, 11, 5, tzinfo=timezone.utc), "https://www.nvidia.com/driver",
            "Fixed an issue where GPU scaling mode was not persisted.", "NVIDIA driver/news")
        self.assertEqual(len(list(watch.pending_alerts([announcement], since, set()))), 1)

    def test_smtp_failure_does_not_advance_checkpoint(self):
        state = {"checked_at": (NOW - timedelta(days=1)).isoformat(), "seen": []}
        with (patch.object(watch, "ZoneInfo", return_value=timezone.utc),
              patch.object(watch, "GitState") as store,
              patch.object(watch, "get_updates", return_value=[update(CFG)]),
              patch.object(watch, "get_nvidia_updates", return_value=[]),
              patch.object(watch, "send_email", side_effect=OSError("unavailable"))):
            store.return_value.load.return_value = state
            with self.assertRaises(OSError):
                watch.run("live")
            store.return_value.save.assert_not_called()

    def test_live_run_records_delivery_and_replay_stays_silent(self):
        now = datetime.now(timezone.utc)
        announcement = update(CFG, posted=now, edited=now)
        with (patch.object(watch, "ZoneInfo", return_value=timezone.utc),
              patch.object(watch, "GitState") as store,
              patch.object(watch, "get_updates", return_value=[announcement]),
              patch.object(watch, "get_nvidia_updates", return_value=[]),
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
