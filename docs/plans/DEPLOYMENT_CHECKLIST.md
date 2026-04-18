# Deployment Checklist for Cache Serialization Fix

## Quick Deploy Steps

### 1. Deploy the code changes
```bash
git pull origin main
```

### 2. Flush Redis (REQUIRED - removes all pickled data)

**Option A: Using Docker (recommended for production)**
```bash
# Get Redis container name
docker ps | grep redis

# Flush Redis database 8
docker exec -it <redis-container-name> redis-cli -n 8 FLUSHDB

# Verify it's empty
docker exec -it <redis-container-name> redis-cli -n 8 DBSIZE
```

**Option B: Using Python script**
```bash
docker exec -it pronext python3 scripts/flush_redis_quick.py
```

### 3. Restart services
```bash
docker-compose restart pronext celery
```

### 4. Verify it's working
```bash
# Check for errors
docker-compose logs -f pronext | grep -i "unicode\|pickle"

# Should see no errors - press Ctrl+C after 30 seconds if no errors
```

## What was fixed?

1. **Device online status** - Fixed key mismatch in `viewset_pad.py`
2. **Celery serialization** - Changed from pickle to JSON in `settings.py`
3. **Redis flush** - Removed all old pickled data

## Why flush Redis?

- Celery was writing pickled data to Redis
- Django tries to read with JSON deserializer
- Causes `UnicodeDecodeError: 'utf-8' codec can't decode byte 0x80`
- Flushing removes ALL old pickled data
- After restart, everything uses JSON

## Verification

After deployment, verify:
- [ ] No UTF-8 decode errors in logs
- [ ] Device online status shows correctly in admin
- [ ] Heartbeat endpoint working (both Django and Go)
- [ ] Celery tasks running successfully

## If errors persist

If you still see UTF-8 errors after following all steps:

1. Check Redis URL is correct in `.env` file
2. Verify you flushed the correct Redis database (should be database 8)
3. Make sure both Django AND Celery were restarted
4. Check that changes to `settings.py` were deployed (verify `CELERY_TASK_SERIALIZER`)

## Rollback

If you need to rollback, the changes are minimal:
- Revert `pronext_server/settings.py` (remove Celery serialization lines)
- Revert `pronext/common/viewset_pad.py` (device online status check)
- Restart services

Note: Rollback will cause the UTF-8 errors to return!
