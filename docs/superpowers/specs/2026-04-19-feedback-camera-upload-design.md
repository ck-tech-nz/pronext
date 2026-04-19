# Feedback Page: Fix Unresponsive Screenshot Upload Button

**Date:** 2026-04-19
**Scope:** `h5/src/pages/support/Feedback.vue` only

## Problem

On the Help & Support page, tapping the camera icon under "Screenshots" does nothing. The page uses Vant's `<van-uploader>`, which internally renders a hidden `<input type="file">`. The Flutter app hosts H5 via `webview_flutter`, which does not implement `WebChromeClient.onShowFileChooser` on Android, so the input click is a no-op. Users cannot attach screenshots.

## Goal

Make the screenshot picker work inside the Flutter WebView. Scope is app-only — no browser fallback needed.

## Approach

Stay in H5. The app already exposes a native media-picker bridge (`mixapp.pickMedia`, wired to Flutter's `image_picker` in `app/lib/src/webview/inner_bridge.dart:182`). Replace `<van-uploader>` in `Feedback.vue` with a small custom thumbnail grid that calls this bridge.

The downstream submission path (`Upload.uploadImage` in `h5/src/base/upload.js`) already supports both `file` (Blob) and app-mode `path` on the image object. We preserve the existing object shape so no changes are needed there or in `feedbackManager.submitFeedback`.

## Design

### UI (in `Feedback.vue`)

Replace the current block:

```html
<van-uploader v-model="formData.images" multiple :max-count="3" :max-size="5*1024*1024" @oversize="onOversize" />
```

with a simple grid:

- Up to 3 slots laid out horizontally.
- Each existing image renders as a 72×72 thumbnail with a small × remove button.
- If fewer than 3 images are selected, show a "+" tile with a camera icon at the end.
- Tapping the "+" tile opens a `<van-action-sheet>` with two options: **Take Photo** and **Choose from Library** (plus Cancel).

### Picker behavior

- **Take Photo** → `mixapp.pickMedia('camera', { cache: true })` (returns 0 or 1 media).
- **Choose from Library** → `mixapp.pickMedia('image', { limit: remaining, cache: true })` where `remaining = 3 - formData.images.length`.

For each returned media `{ path, type, hash }`:

1. Read base64 from the Dart-side cache: `await mixapp.cache.getItem(hash)`.
2. Convert base64 → `Uint8Array` → `Blob` → `File` (name derived from `path`, mime from `type`).
3. Build an object compatible with the existing submission flow:
   ```js
   { file, path, url: `data:${type};base64,${base64}`, hash }
   ```
   - `file`: used by `Upload.uploadImage` to compute the presigned upload payload.
   - `path`: used as the native-file path for `mixapp.upload` in app mode.
   - `url`: used as the `<img>` src for the thumbnail.

4. Push into `formData.images`.

### Submit flow

Unchanged. `Upload.uploadImage(fileObj, 'support')` already:

- Reads `fileObj.file` to build the `file_data` base64 in the presigned-URL request.
- When the response contains `upload_url` and `mixapp.isApp` is true, calls `mixapp.upload(upload_url, fileObj.path)` (native HTTP PUT of the file bytes).

So keeping `{file, path}` on each image means no manager/request changes.

### Error and edge handling

- If `mixapp.cache.getItem(hash)` returns empty, skip that media and toast "Failed to read image, please try again" (defensive — not expected in practice since `cache: true` is set).
- 5 MB size check: after building the `File`, drop and toast `"File size cannot exceed 5MB"` if `file.size > 5 * 1024 * 1024` (preserves the current limit).
- Do nothing if the user cancels the picker (empty medias array).

### What stays the same

- `formData.images` stays a flat array; `max-count = 3`.
- `feedbackManager.submitFeedback` and `Upload.uploadImage` untouched.
- The "×" remove icon is inline HTML, no van-uploader needed.

## Non-goals

- No changes to the Flutter app. No `WebChromeClient` wiring. No new Flutter page.
- No browser/dev fallback path (user confirmed app-only is sufficient).
- No additional image formats or video support beyond what `image_picker` returns for `type: 'image' | 'camera'`.

## Test plan (manual, Android emulator)

1. Open app → Help & Support.
2. Tap the "+" tile → action sheet shows "Take Photo" / "Choose from Library".
3. Take Photo: camera opens, capture an image, thumbnail appears.
4. Choose from Library: gallery opens, select up to 3; thumbnails appear.
5. Remove a thumbnail via ×; "+" tile reappears when count drops below 3.
6. Submit with description + at least one image; verify attachment appears on the backend (`/support/feedback/unclosed/`) and thumbnails are downloadable.
7. Try attaching a >5 MB image; verify it's rejected with a toast.
