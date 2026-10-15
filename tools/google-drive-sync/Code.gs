const FOLDER_ID = '1MMAeVZIvbtTxBu3aBkJAzt8W7fYBg2DK';

function doPost(e) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) {
    throw new Error('Another launcher upload is running. Retry the GitHub Actions job.');
  }

  try {
    const payload = JSON.parse(e.postData.contents);
    const expectedToken = PropertiesService.getScriptProperties().getProperty('DRIVE_SYNC_TOKEN');
    if (!expectedToken || !payload.token || payload.token !== expectedToken) {
      throw new Error('Unauthorized.');
    }
    if (typeof payload.content !== 'string' || typeof payload.release !== 'string') {
      throw new Error('Invalid upload payload.');
    }

    const incomingVersion = parseRelease_(payload.content);
    if (incomingVersion !== payload.release) {
      throw new Error('Release marker does not match the payload.');
    }

    const folder = DriveApp.getFolderById(FOLDER_ID);
    const files = folder.getFilesByName('cafe.bat');
    if (!files.hasNext()) throw new Error('No cafe.bat exists in the configured Drive folder.');
    const file = files.next();
    if (files.hasNext()) throw new Error('Multiple cafe.bat files exist in the folder; refusing to choose one.');

    const existingContent = file.getBlob().getDataAsString('UTF-8');
    const existingVersion = parseRelease_(existingContent);
    const comparison = compareVersions_(incomingVersion, existingVersion);
    if (comparison < 0) throw new Error('Refusing to replace a newer Drive release.');
    if (comparison === 0) {
      if (existingContent !== payload.content) {
        throw new Error('Release version matches but file contents differ; bump CAFE_RELEASE first.');
      }
      return json_({ok: true, release: payload.release, unchanged: true});
    }

    file.setContent(payload.content); // Keep the existing Drive file ID and link.
    return json_({ok: true, release: payload.release, unchanged: false});
  } finally {
    lock.releaseLock();
  }
}

function parseRelease_(content) {
  const match = content.match(/^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)\s*$/m);
  if (!match) throw new Error('A valid CAFE_RELEASE marker is required.');
  return match[1];
}

function compareVersions_(left, right) {
  const a = left.split('.').map(Number);
  const b = right.split('.').map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const difference = (a[i] || 0) - (b[i] || 0);
    if (difference !== 0) return difference < 0 ? -1 : 1;
  }
  return 0;
}

function json_(value) {
  return ContentService.createTextOutput(JSON.stringify(value))
    .setMimeType(ContentService.MimeType.JSON);
}
