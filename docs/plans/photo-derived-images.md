# Photo Derived Images and Video Thumbnails

## Background

On iOS real devices, loading many full-size images inside the embedded WebView can trigger `webContentProcessTerminated`, and Flutter will reload the WebView. This looks like the Photos page "refreshes" and jumps back to the top.

To reduce decoding/memory pressure, the server provides derived image URLs and video thumbnail URLs, and generates these files in object storage.

## Upload Architecture

The system uses **client-side direct upload to S3**:

- App uploads files directly to S3 using presigned URLs
- Files do **not** pass through the backend server
- Backend only receives the S3 URL after upload completes
- This saves server bandwidth and improves upload speed
- Trade-off: derived file generation requires downloading from S3

**Why download from S3?** Because files never pass through the backend during upload, the backend must download them to generate thumbnails.

## Design Philosophy

**Key decisions:**
- ✅ Only generate on upload (not on list requests)
- ✅ Return derived URLs immediately (don't wait for generation)
- ✅ Backward compatible (old files without thumbnails work fine)
- ✅ Progressive improvement (new uploads automatically get thumbnails)

**与图片派生图片（thumb/display）保持一致的设计：**
- 用户只上传原始文件
- 后端自动异步生成派生文件
- API 立即返回派生 URL
- 前端渐进式加载

## File Naming Rules

### Images

- Original: `https://s.pronextusa.com/1f/abc123.jpg`
- Thumb: `https://s.pronextusa.com/1f/thumb_abc123.jpg`
- Display: `https://s.pronextusa.com/1f/display_abc123.jpg`

### Videos

- Original: `https://s.pronextusa.com/1f/video123.mp4`
- Thumb: `https://s.pronextusa.com/1f/thumb_video123.jpg` ← **Note: .jpg extension**
- Display: `null` (videos don't need display variant)

## API Endpoints and Output

### List Endpoint

`GET /app-api/photo/device/<device_id>/list`

Each media item keeps `url` unchanged and adds:

- `thumb_url`: same folder, filename prefixed with `thumb_`
- `display_url`: same folder, filename prefixed with `display_` (images only)

### Response Example (Image)

```json
{
  "id": 123,
  "url": "https://s.pronextusa.com/1f/image.jpg",
  "thumb_url": "https://s.pronextusa.com/1f/thumb_image.jpg",
  "display_url": "https://s.pronextusa.com/1f/display_image.jpg",
  "media_type": 1
}
```

### Response Example (Video)

```json
{
  "id": 124,
  "url": "https://s.pronextusa.com/1f/video.mp4",
  "thumb_url": "https://s.pronextusa.com/1f/thumb_video.jpg",
  "display_url": null,
  "media_type": 2
}
```

**Notes:**
- Videos only get `thumb_url` (extracted from first frame)
- The API does **not** synchronously check whether derived files exist
- URLs are returned immediately via pure URL transformation

## Generation Specifications

### Image Derived Images

| Variant | Max Side | Format | Quality | Notes |
|---------|----------|--------|---------|-------|
| thumb   | 768px    | JPEG   | 78      | For list view |
| display | 2048px   | JPEG   | 85      | For detail view |

- EXIF orientation is applied (`ImageOps.exif_transpose`)
- Truncated images are allowed during processing (via context manager)

### Video Thumbnails

| Property | Value |
|----------|-------|
| Source   | First frame |
| Max Side | 768px |
| Format   | JPEG |
| Quality  | 78 |

- Same specs as image thumb variant
- Uses opencv-python-headless for frame extraction
- Always saved as `.jpg` regardless of video format

## Server-Side Behavior

### Implementation Location

- Serializer: `pronext/photo/viewsets_app.py::MediaSerializer`
- List endpoint: `pronext/photo/viewsets_app.py::MediaViewSet._list`
- Add endpoint: `pronext/photo/viewsets_app.py::MediaViewSet.add`
- Generation logic: `pronext/photo/derived_images.py`

### When Generation is Triggered

Derived file generation is scheduled asynchronously (thread pool) **only** when:
- A new media record is created (add endpoint)

**List endpoint does NOT trigger generation** to minimize server load.

### Workflow

1. **Upload**
   - App gets presigned URL from `/common/presigned_upload_url`
   - App uploads file directly to S3
   - App calls `/photo/device/{id}/add` with the S3 URL

2. **Backend Processing**
   - Creates Media record
   - **Immediately schedules async generation task** (only on upload)
   - Returns response immediately (doesn't wait)

3. **Async Generation**
   - Thread pool worker picks up task
   - Downloads file from S3 to temp file (for videos)
   - Images: generates thumb + display variants
   - Videos: extracts first frame for thumb
   - Uploads derived files to S3
   - Cleans up temp files

4. **List Request**
   - Returns derived URLs via URL transformation
   - **Does NOT trigger any generation tasks**

5. **Frontend Display**
   - Tries to load derived URL
   - Success: shows thumbnail ✅
   - Failure: falls back to original/placeholder ✅

## Client-Side Behavior

Implementation: `h5/src/pages/photos/Photos.vue`

What happens:

- **Grid thumbnails**: Use `thumb_url` first, fall back to `url` on error
- **Image preview**: Use `display_url` first, fall back to `url` on error
- **Video preview**: Play original `url` directly (no display variant)
- **Videos without thumbnails**: Show black background + play icon

This allows:
- Fast list API responses (no per-item storage checks)
- Progressive improvement as derived files are generated
- Graceful degradation for missing thumbnails

## Error Handling

### Truncated Images

Image processing uses `allow_truncated_images()` context manager:

```python
with allow_truncated_images():
    image = Image.open(source)  # Only here
# Setting restored after block
```

**Trade-off:**
- ✅ Handles network interruptions during S3 downloads
- ⚠️ Might process incomplete data
- ✅ Scoped to specific operations only
- ✅ No impact on rest of application

### Generation Failures

- Backend fails silently and logs errors
- API still returns thumb_url
- Frontend handles 404 gracefully with fallback
- User experience degrades but functionality doesn't break

## Concurrency and Deduplication

### Process-Local Protection

```python
_derive_inflight = set()      # Track in-progress files
_derive_lock = threading.Lock()  # Thread-safe access
_derive_slots = BoundedSemaphore(32)  # Limit concurrency
```

**Design philosophy:**
- Generation only triggered on upload
- List endpoint doesn't trigger generation
- Old files without thumbnails: frontend falls back
- New uploads: automatically get thumbnails

### Known Limitation: Multi-Process Race Condition

**What:**
- Multiple processes (e.g., gunicorn workers) might process same file

**Result:**
- Duplicate work, later write overwrites earlier
- No data corruption

**Probability:**
- Very low in practice

**Why not distributed locking?**
- Adds complexity and latency
- Requires infrastructure (Redis/Postgres)
- Marginal benefit for rare edge case
- Acceptable to occasionally waste resources

### Storage-Level Check

- Each function checks `storage.exists()` before processing
- Not atomic (check-then-act pattern)
- Additional protection but same limitation as above

## Deletion Behavior

Implementation: `pronext/photo/models.py::MediaQuerySet.bulk_delete_with_files`

When a media record is deleted:

**For images:**
- Original file
- `thumb_` file
- `display_` file

**For videos:**
- Original file
- `thumb_` file (.jpg)

All keys derived from original `url` and deleted asynchronously.

## Testing

### Quick Verification

```bash
# 1. Check imports
cd /path/to/server
source venv/bin/activate
python3 -c "from pronext.photo.derived_images import ensure_video_thumbnail; print('✓ OK')"

# 2. Run server
python3 manage.py runserver 0.0.0.0:8888

# 3. Upload a video via app or API

# 4. Check list response
curl -H "Authorization: Bearer YOUR_TOKEN" \
  http://localhost:8888/app-api/photo/device/{id}/list
```

### Expected Results

- API returns immediately with `thumb_url`
- After a few seconds, `thumb_url` should be accessible
- Frontend correctly displays video thumbnails
- List requests don't trigger tasks (check logs)

### Manual Generation (Helper Command)

For testing or warming up cache for existing files:

```bash
python3 manage.py generate_photo_derivatives <device_user_id>
```

This command:
- Generates thumb/display for all images
- Generates thumb for all videos
- Useful for migrating old data

## Deployment

### Requirements

1. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

2. **Restart server**
   ```bash
   systemctl restart server  # or your deployment method
   ```

3. **Optional: Generate for existing files**
   ```bash
   python3 manage.py generate_photo_derivatives <device_user_id>
   ```

**Note:** No database migration needed - URLs are derived via rules.

### Dependencies

**Image processing:**
- `pillow==11.2.1`

**Video processing:**
- `opencv-python-headless==4.12.0.88`

## Performance Considerations

### Optimizations

- ✅ List requests don't trigger generation (major load reduction)
- ✅ Thread pool for async processing (4 workers default)
- ✅ Concurrent task limit (32 max)
- ✅ Process-local deduplication
- ✅ Storage exists() check before processing

### Limitations

- Video processing is slower than images
- First frame extraction requires downloading entire video
- Multi-process: possible duplicate work (rare, acceptable)

### Configuration

Settings can be adjusted:

```python
# In settings.py
PHOTO_DERIVED_IMAGE_WORKERS = 4  # Thread pool size
PHOTO_DERIVED_IMAGE_MAX_INFLIGHT = 32  # Max concurrent tasks
```

## Implementation Files

### Backend (server)

```
pronext/photo/
├── models.py              # Media model, deletion cleanup
├── derived_images.py      # Core generation logic
│   ├── ensure_derived_image()
│   ├── ensure_video_thumbnail()
│   ├── allow_truncated_images()
│   └── URL/key helpers
└── viewsets_app.py        # API endpoints, scheduling
    ├── MediaSerializer
    ├── MediaViewSet
    └── _schedule_* functions
```

### Frontend (vue)

```
src/pages/photos/
└── Photos.vue             # Display logic, fallback handling
```

### Documentation

```
docs/
└── photo-derived-images.md  # This file
```

## Summary

**What we built:**
- Automatic thumbnail generation for images and videos
- Client-side direct upload to S3
- Async background processing
- Backward compatible with old data
- Minimal server load on list requests

**Key benefits:**
- ✅ Faster uploads (direct to S3)
- ✅ Reduced memory pressure in iOS WebView
- ✅ Progressive enhancement (old files work, new files better)
- ✅ Scalable (async processing, bounded concurrency)
- ✅ Simple (no additional infrastructure needed)

**Trade-offs:**
- ⚠️ Must download from S3 to process
- ⚠️ Possible duplicate work in multi-process (rare, acceptable)
- ⚠️ Old files don't get thumbnails automatically (can run manual command)

---

*Last updated: 2024-12-14*
