# Google Drive launcher mirror

The `publish-drive` job in `cafe-syntax.yml` updates the existing `cafe.bat` in the linked Drive folder after all five validation jobs pass on `main`. It updates the file in place, preserving its Drive file ID and link; the folder URL and any Bitly redirect to it stay unchanged. It refuses missing or duplicate files, invalid release markers, and version downgrades. For an equal release number, GitHub `main` is the source of truth: differing file contents are replaced in place.

## One-time Google setup

1. Open [Google Apps Script](https://script.google.com/) while signed into the account that owns or can edit the Drive folder.
2. Create a standalone project and replace its `Code.gs` with this repository's `tools/google-drive-sync/Code.gs`.
3. In **Project Settings → Script Properties**, add `DRIVE_SYNC_TOKEN` with a newly generated, long random value. Keep it private.
4. Deploy as a **Web app**, executing as yourself, with access set to **Anyone** so GitHub's runner can call it. The script checks the secret token before it touches Drive. If Google Workspace policy does not allow anonymous web apps, use the Drive API with OAuth instead.
5. Copy the deployed `/exec` URL. In the GitHub repository, add Actions secrets named `DRIVE_SYNC_URL` and `DRIVE_SYNC_TOKEN`; set them to the web app URL and the same random token.
6. Confirm there is exactly one file named `cafe.bat` directly inside the folder linked by `1MMAeVZIvbtTxBu3aBkJAzt8W7fYBg2DK` and that the deploying Google account can edit it.

Google may ask the script owner to authorize Drive access because Apps Script's Drive service uses the owner's permissions. The script code only looks for and updates `cafe.bat` in the configured folder; the web app should not be shared with other users.

After setup, pushes that change `cafe.bat` on `main` publish automatically after validation. A manual run of **CafeLauncher syntax check** from the `main` branch also republishes the current version. Context-only or test-only pushes skip the upload. The request token is sent in the POST body, not the URL, and neither the workflow nor the script logs it.
