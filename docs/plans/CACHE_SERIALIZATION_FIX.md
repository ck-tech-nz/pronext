# Cache Serialization Fix

## Problem Summary

After deploying the Go heartbeat service and updating Django to use JSON serialization for django-redis, two critical issues were discovered:

1. **Device online status showing incorrect** - Devices weren't showing as online even when sending heartbeats
2. **UTF-8 decode errors** - Django crashed with `UnicodeDecodeError: 'utf-8' codec can't decode byte 0x80`

## Root Causes

### Issue 1: Device Online Status Key Mismatch

**Problem:**
- Django's `heartbeat()` method checked online status using `cache.get(f"device:online:{device_sn}")` (line 115)
- This automatically adds django-redis prefix `:1:`, checking key `:1:device:online:{device_sn}`
- But `_update_online_status()` writes to raw Redis key `device:online:{device_sn}` (no prefix)
- Go service also uses `device:online:{device_sn}` (no prefix)
- Result: Django was reading from the wrong key and always thought devices were offline

**Fix:**
Changed Django's `heartbeat()` method to use raw Redis client (bypassing django-redis prefix):

```python
# Before (WRONG - adds :1: prefix)
if not cache.get(f"{ONLINE_STATUS_PREFIX}{device_sn}"):
    self._update_online_status(device_sn)

# After (CORRECT - no prefix)
redis_client = cache.client.get_client()
online_key = f"{ONLINE_STATUS_PREFIX}{device_sn}"
if not redis_client.exists(online_key):
    self._update_online_status(device_sn)
```

Also updated `get_device_online_status()` to ensure it returns a boolean correctly.

**Files changed:**
- `pronext/common/viewset_pad.py` - Fixed heartbeat method and get_device_online_status function

### Issue 2: Pickled Data in Redis Cache

**Root Cause:**
- Django cache was configured to use JSON serialization
- **Celery was NOT configured and defaulted to pickle serialization**
- Celery writes task data and cache entries to Redis using pickle
- When Django tries to read Celery's pickled data with JSON deserializer, it crashes
- The error cascaded through Django's URL loading, making the entire application unavailable

**Why flushing Redis works initially but problem returns:**
1. You flush Redis - all pickled data is cleared
2. Django creates new keys with JSON serialization
3. Celery writes new keys using pickle (default behavior)
4. Django tries to read Celery's pickled data with JSON deserializer → crash

**Fix:**
Configured Celery to use JSON serialization in `pronext_server/settings.py`:

```python
# Use JSON serialization to match django-redis (not pickle)
# This prevents UTF-8 decode errors when Django reads Celery cache keys
CELERY_TASK_SERIALIZER = 'json'
CELERY_RESULT_SERIALIZER = 'json'
CELERY_ACCEPT_CONTENT = ['json']
```

This ensures both Django and Celery use the same serialization format.

**Files changed:**
- `pronext_server/settings.py` - Added Celery JSON serialization settings

## Additional Tools

### Cache Cleanup Script

Created `scripts/clean_pickled_cache.py` to identify and clean pickled data:

```bash
# Dry run - show pickled keys
python3 scripts/clean_pickled_cache.py

# Delete pickled keys
python3 scripts/clean_pickled_cache.py --delete

# Flush entire database (use with caution!)
python3 scripts/clean_pickled_cache.py --flush-all
```

This script:
- Scans Redis for keys containing pickled data (`\x80\x04...`)
- Shows which keys are affected
- Optionally deletes them
- Prevents future UTF-8 errors

## Deployment Steps

After deploying these fixes to production:

1. **Flush Redis completely** (required to remove all pickled data):
   ```bash
   source ./venv/bin/activate
   python3 scripts/clean_pickled_cache.py --flush-all -y
   ```

2. **Restart all services** (both Django and Celery):
   ```bash
   docker-compose restart pronext celery
   ```

3. **Monitor logs** to verify no serialization errors:
   ```bash
   docker-compose logs -f pronext | grep -i "unicode\|pickle"
   ```

4. **Verify device online status**:
   - Check admin panel for online devices
   - Verify heartbeat responses are correct

## Prevention

To prevent this issue from recurring:

1. **Keep Celery JSON serialization settings** in place (never remove them)
2. **Always use JSON serialization** for any new cache configurations
3. **Monitor logs** after deployments for serialization errors
4. **Test serialization compatibility** before adding new background job systems

## Technical Details

### Django-Redis Key Prefixing

Django-redis automatically adds `:1:` prefix to all cache keys:
- Cache operation: `cache.set("mykey", value)`
- Actual Redis key: `:1:mykey`

This is for cache versioning. When using raw Redis client for compatibility with Go service:
- Use `cache.client.get_client()` to bypass prefix
- Keys like `device:online:{sn}` are stored without prefix
- Both Django and Go can read/write these keys

### Pickle Protocol Markers

Pickled data starts with these bytes:
- `\x80\x04` - Pickle protocol 4 (Python 3.4+)
- `\x80\x03` - Pickle protocol 3
- `\x80\x02` - Pickle protocol 2

JSON data never starts with these bytes, making them easy to detect.

## Related Documentation

- `go-heartbeat/README.md` - Go heartbeat service documentation
- `CLAUDE.md` - Project structure and architecture
- `docs/PAD_AUTHENTICATION.md` - Pad device authentication

## Testing

After applying these fixes, verify:

1. Device online status shows correctly in admin panel
2. No UTF-8 decode errors in logs
3. Heartbeat requests succeed for both Django and Go services
4. Config admin pages load without errors

## Summary

**Root Cause:** Celery was using pickle serialization while Django used JSON, causing UTF-8 decode errors.

**Solution:** Configure Celery to use JSON serialization to match Django.

These fixes resolve:
1. Device online status key mismatch between Django and Go service
2. Cache serialization conflicts between Django and Celery
3. Recurring UTF-8 decode errors after Redis flushes

After applying these fixes, the system will use consistent JSON serialization across all components (Django, Go, Celery).
