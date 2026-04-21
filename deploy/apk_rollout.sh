#!/bin/bash
# =============================================
# PadApk Rollout control script
# File: apk_rollout.sh
#
# Usage:
#   ./apk_rollout.sh                        # show current state
#   ./apk_rollout.sh start                  # resume  (is_paused=False)
#   ./apk_rollout.sh start -f               # resume, then follow
#   ./apk_rollout.sh start -f -t 10         # follow at 10s (min 5)
#   ./apk_rollout.sh -f                     # follow only, no state change
#   ./apk_rollout.sh -f --watchdog          # follow + auto-STOP on pg18 storm
#   ./apk_rollout.sh -f --log rollout.log   # mirror to custom file (else auto-named in CWD)
#   ./apk_rollout.sh -f --all               # count ALL PadDevice (default: active only)
#   ./apk_rollout.sh stop                   # pause  (is_paused=True)
#
# Notes:
#   - Targets the latest PUBLISHED APK (order by -build_num).
#   - Flips the is_paused field only; status is NOT touched.
#   - 'stop' halts NEW download notifications; devices already
#     downloading or installing will complete — there is no "rollback".
#   - Progress % excludes skip_devices and devices inactive for
#     > ACTIVE_DAYS days, unless --all is passed.
#   - All timestamps are printed in Asia/Shanghai (CST).
#   - Every run writes to a log: default ./apk_rollout_<YYYYMMDD-HHMMSS>.log
#     in CWD; override with --log FILE; disable with --log /dev/null.
#   - The --watchdog brake uses DIRECT psql (not Django ORM) so it
#     still works when Django's connection pool is itself starved.
# =============================================

set -euo pipefail

# ---- Tunables -------------------------------------------------------------
CONTAINER_NAME="pronext"
PG_CONTAINER="pg18"
MIN_INTERVAL=5
ACTIVE_DAYS=30
WATCHDOG_WINDOW="60s"
TZ_NAME="Asia/Shanghai"

usage() {
    cat <<EOF
Usage:
  $0                                # show current state
  $0 start [-f] [-t N] [options]    # resume rollout, optionally follow
  $0 stop                           # pause rollout (halts NEW notifications only)
  $0 -f [-t N] [options]            # follow progress without state change

Options (follow mode):
  -t, --interval N   poll interval seconds (min $MIN_INTERVAL; smaller values are clamped)
  --all              count ALL PadDevice rows (default: excludes stale > ${ACTIVE_DAYS}d and skip_devices)
  --watchdog         auto-pause via DIRECT psql if pg18 logs 'too many clients already' in last $WATCHDOG_WINDOW
  --log FILE         mirror output to FILE (default: auto-named in CWD; use /dev/null to suppress)
EOF
    exit 1
}

# ---- arg parsing ----------------------------------------------------------
MODE="status"
FOLLOW=0
INTERVAL=5
USE_ALL=0
WATCHDOG=0
LOG_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        start|stop)     MODE="$1"; shift;;
        -f|--follow)    FOLLOW=1; shift;;
        -t|--interval)  INTERVAL="${2:-}"; shift 2 || usage;;
        --all)          USE_ALL=1; shift;;
        --watchdog)     WATCHDOG=1; shift;;
        --log)          LOG_FILE="${2:-}"; shift 2 || usage;;
        -h|--help)      usage;;
        *)              usage;;
    esac
done

if ! [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid -t value: '$INTERVAL' (positive integer required)"; exit 1
fi
if [ "$INTERVAL" -lt "$MIN_INTERVAL" ]; then
    echo "Interval clamped from $INTERVAL to ${MIN_INTERVAL}s (each tick runs ORM aggregates)"
    INTERVAL=$MIN_INTERVAL
fi

if [ "$MODE" = "stop" ] && [ "$FOLLOW" -eq 1 ]; then
    echo "Cannot combine 'stop' with -f (nothing to follow after pausing)."; exit 1
fi

if [ "$MODE" = "start" ]; then NEW_PAUSED=False; ACTION="RESUME"; fi
if [ "$MODE" = "stop"  ]; then NEW_PAUSED=True;  ACTION="PAUSE";  fi

# R7 / user request: --log is optional; default to an auto-named file in CWD.
# Pass `--log /dev/null` to truly suppress.
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="./apk_rollout_$(TZ="$TZ_NAME" date '+%Y%m%d-%H%M%S').log"
fi

# ---- output helpers -------------------------------------------------------
outln() {
    echo "$1"
    echo "$1" >>"$LOG_FILE"
}

# R8 / R12: local (China) timestamps
ts_now() { TZ="$TZ_NAME" date '+%m-%d %H:%M:%S'; }

# ---- container check ------------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' is not running (check with 'docker ps')"; exit 1
fi

# ---- fetch latest PUBLISHED state -----------------------------------------
INFO=$(docker exec -i "$CONTAINER_NAME" python manage.py shell <<PYEOF
from pronext.common.models import PadApk
from pronext.device.models import PadDevice
from django.db.models import Avg, Max
from django.utils import timezone
from datetime import timedelta
try:
    from zoneinfo import ZoneInfo
except ImportError:
    from pytz import timezone as ZoneInfo  # fallback

v = PadApk.objects.filter(status=PadApk.Status.PUBLISHED).order_by('-build_num').first()
if v is None:
    print("NOT_FOUND")
else:
    state = "🛑 PAUSED" if v.is_paused else "✅ ROLLING OUT"
    skip = v.skip_devices or []
    if skip:
        head = ",".join(str(s) for s in skip[:3])
        more = "..." if len(skip) > 3 else ""
        skip_line = f"{len(skip)} ({head}{more})"
    else:
        skip_line = "0"

    # R13: fleet state vs latest
    agg = PadDevice.objects.aggregate(avg=Avg('app_build_num'), max=Max('app_build_num'))
    avg_build = int(agg['avg'] or 0)
    max_build = agg['max'] or 0
    lag = v.build_num - avg_build

    # R12: show published_at in CST (in addition to UTC)
    pub_cst = "(not set)"
    if v.published_at:
        try:
            pub_cst = v.published_at.astimezone(ZoneInfo('$TZ_NAME')).strftime('%Y-%m-%d %H:%M:%S %Z')
        except Exception as e:
            pub_cst = f"(tz conversion failed: {e})"

    print("=== Latest PUBLISHED PadApk ===")
    print(f"state:              {state}")
    print(f"id:                 {v.id}")
    print(f"version:            {v.version}")
    print(f"build_num:          {v.build_num}")
    print(f"status:             {v.status} (PUBLISHED)")
    print(f"is_paused:          {v.is_paused}")
    print(f"window_seconds:     {v.window_seconds}")
    print(f"published_at_utc:   {v.published_at}")
    print(f"published_at_cst:   {pub_cst}")
    print(f"skip_devices:       {skip_line}")
    print(f"fleet_avg_build:    {avg_build}")
    print(f"fleet_max_build:    {max_build}")
    print(f"lag_vs_latest:      {lag}")
    print("================================")
PYEOF
)

outln "$INFO"

if echo "$INFO" | grep -q "NOT_FOUND"; then
    outln "No PadApk with status=PUBLISHED found."
    outln "(Hint: mark the target APK as PUBLISHED in admin first.)"
    exit 1
fi

VERSION=$(echo "$INFO"   | awk '/^version:/   {print $2}')
BUILD_NUM=$(echo "$INFO" | awk '/^build_num:/ {print $2}')

# ---- follow loop ----------------------------------------------------------
follow_progress() {
    local build_num="$1"
    local interval="$2"
    local prev_upgraded=""
    local start_ts
    start_ts=$(date +%s)

    trap 'echo; echo "Follow stopped."; exit 0' INT

    outln ""
    outln "Following rollout for build=$build_num every ${interval}s (Ctrl+C to stop)..."
    if [ "$USE_ALL" -eq 0 ]; then
        outln "Filter: active devices only (updated_at within ${ACTIVE_DAYS}d, app_build_num>0, excluding skip_devices)"
    else
        outln "Filter: ALL PadDevice rows (--all)"
    fi
    if [ "$WATCHDOG" -eq 1 ]; then
        outln "Watchdog: will auto-STOP if pg18 logs 'too many clients' in last $WATCHDOG_WINDOW"
    fi
    [ -n "$LOG_FILE" ] && outln "Logging to: $LOG_FILE"
    outln ""

    while :; do
        STATS=$(docker exec -i "$CONTAINER_NAME" python manage.py shell <<PYEOF 2>/dev/null || true
from pronext.common.models import PadApk
from pronext.device.models import PadDevice
from django.utils import timezone
from datetime import timedelta

v = PadApk.objects.filter(build_num=$build_num).first()
if v is None:
    print("GONE=1")
else:
    USE_ALL = $USE_ALL
    ACTIVE_DAYS = $ACTIVE_DAYS
    if USE_ALL:
        base = PadDevice.objects.all()
    else:
        cutoff = timezone.now() - timedelta(days=ACTIVE_DAYS)
        skip_sns = v.skip_devices or []
        base = PadDevice.objects.filter(app_build_num__gt=0, updated_at__gte=cutoff).exclude(sn__in=skip_sns)
    upgraded = base.filter(app_build_num__gte=v.build_num).count()
    pending  = base.filter(app_build_num__lt=v.build_num).count()
    total    = upgraded + pending
    pct      = (upgraded/total*100) if total else 0

    # R3: expected % based on window_seconds progress
    if v.published_at and v.window_seconds and v.window_seconds > 0:
        elapsed = (timezone.now() - v.published_at).total_seconds()
        expected = min(100.0, max(0.0, elapsed / v.window_seconds * 100))
    else:
        expected = 0.0

    print(f"upgraded={upgraded}")
    print(f"total={total}")
    print(f"pct={pct:.1f}")
    print(f"expected={expected:.1f}")
    print(f"skip={len(v.skip_devices or [])}")
    print(f"paused={v.is_paused}")
PYEOF
        )

        # R5: resilience — docker exec or Python shell failed
        if [ -z "$STATS" ]; then
            outln "[$(ts_now)] stats unavailable (container restart?); retrying in ${interval}s..."
            sleep "$interval"
            continue
        fi

        if echo "$STATS" | grep -q '^GONE='; then
            outln "[$(ts_now)] APK build=$build_num no longer exists. Stopping follow."
            break
        fi

        upgraded=$(echo "$STATS" | awk -F= '$1=="upgraded" {print $2; exit}')
        total=$(   echo "$STATS" | awk -F= '$1=="total"    {print $2; exit}')
        pct=$(     echo "$STATS" | awk -F= '$1=="pct"      {print $2; exit}')
        expected=$(echo "$STATS" | awk -F= '$1=="expected" {print $2; exit}')
        skip=$(    echo "$STATS" | awk -F= '$1=="skip"     {print $2; exit}')
        paused=$(  echo "$STATS" | awk -F= '$1=="paused"   {print $2; exit}')

        if [ -z "$upgraded" ] || [ -z "$total" ]; then
            outln "[$(ts_now)] stats parse failed; retrying in ${interval}s..."
            sleep "$interval"
            continue
        fi

        delta_str=""
        if [ -n "$prev_upgraded" ]; then
            delta=$((upgraded - prev_upgraded))
            if [ "$delta" -gt 0 ]; then delta_str=" (+$delta)"; fi
        fi

        # R3: health indicator based on (expected - actual)
        # on-track: actual >= expected-5
        # slow:     expected-15 <= actual < expected-5
        # stall:    actual < expected-15
        health="📈"
        if awk -v a="$pct" -v e="$expected" 'BEGIN{exit !(a + 15 < e)}'; then
            health="🐢 slow"
        fi
        if awk -v a="$pct" -v e="$expected" 'BEGIN{exit !(a + 30 < e)}'; then
            health="🚨 stall"
        fi

        badge="✅ rolling"
        [ "$paused" = "True" ] && badge="🛑 paused"

        elapsed=$(( $(date +%s) - start_ts ))
        line=$(printf '[%s  +%02d:%02d]  upgraded=%s/%s (%s%%)%s  expected=%s%%  %s  skip=%s  %s' \
            "$(ts_now)" $((elapsed/60)) $((elapsed%60)) \
            "$upgraded" "$total" "$pct" "$delta_str" "$expected" "$health" "$skip" "$badge")
        outln "$line"

        # R6: watchdog — if pg18 storms, PAUSE via DIRECT psql, NOT via Django.
        # Django's connection pool may itself be blocked waiting for a PG slot;
        # psql inside the pg18 container uses the Unix socket and PG's reserved
        # superuser slots (superuser_reserved_connections, default 3), so the
        # emergency brake still works even when application connections are starved.
        if [ "$WATCHDOG" -eq 1 ] && [ "$paused" = "False" ]; then
            fatal_count=$(docker logs "$PG_CONTAINER" --since "$WATCHDOG_WINDOW" 2>&1 \
                | grep -c "sorry, too many clients already" || true)
            if [ "$fatal_count" -gt 0 ]; then
                outln ""
                outln "[$(ts_now)] ⚠️  WATCHDOG TRIPPED: pg18 logged $fatal_count 'too many clients' in last $WATCHDOG_WINDOW"
                outln "[$(ts_now)] Pausing via DIRECT psql (bypassing Django pool)..."

                # 1) Raw UPDATE via pg18's Unix socket as postgres superuser.
                #    Filters by status=2 (PUBLISHED) and build_num to avoid clobbering
                #    other rows. AND is_paused=false so we only update when needed.
                WD_SQL=$(docker exec -i "$PG_CONTAINER" psql -U postgres -d pronext_prod -tA \
                    -c "UPDATE common_padapk SET is_paused=true, updated_at=now() WHERE status=2 AND build_num=$build_num AND is_paused=false RETURNING id;" 2>&1 || true)
                outln "[$(ts_now)] psql: $WD_SQL"

                # 2) Post_save signal did NOT fire (raw SQL), so APK cache is stale.
                #    Delete the Django-redis keys directly. Keys have :1: prefix from django-redis.
                REDIS_PWD=$(docker exec "$CONTAINER_NAME" sh -c 'echo "$DJANGO_REDIS"' 2>/dev/null \
                    | sed -nE 's|^redis://:([^@]+)@.*|\1|p')
                if [ -n "$REDIS_PWD" ]; then
                    WD_CACHE=$(docker exec -e REDISCLI_AUTH="$REDIS_PWD" bcps-redis-1 \
                        redis-cli --no-auth-warning DEL ":1:latest_apk:testing" ":1:latest_apk:published" 2>&1 || true)
                    outln "[$(ts_now)] redis DEL: $WD_CACHE (number of keys removed)"
                else
                    outln "[$(ts_now)] ⚠️  Could not extract Redis password — APK cache NOT cleared. Manually: redis-cli DEL ':1:latest_apk:published'"
                fi

                outln "Rollout paused via watchdog. Follow loop exiting."
                outln "Verify with: $0"
                break
            fi
        fi

        prev_upgraded="$upgraded"
        sleep "$interval"
    done
}

# ---- status-only (maybe follow) -------------------------------------------
if [ "$MODE" = "status" ]; then
    if [ "$FOLLOW" -eq 1 ]; then
        follow_progress "$BUILD_NUM" "$INTERVAL"
    fi
    exit 0
fi

# ---- confirm + apply ------------------------------------------------------
outln ""
outln "Target: $ACTION  v${VERSION}  (build ${BUILD_NUM})"
if [ "$MODE" = "stop" ]; then
    outln ""
    outln "⚠️  'stop' halts NEW download notifications only."
    outln "    Devices already downloading / installing WILL COMPLETE the upgrade."
    outln "    To truly revert, a new APK with the old build must be published."
fi
read -r -p "Confirm? [y/N]: " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Aborted (confirmation not received)."; exit 1;;
esac

echo "Applying change..."

# R4: re-check latest PUBLISHED at apply time, fail clearly if stale
RESULT=$(docker exec -i "$CONTAINER_NAME" python manage.py shell <<PYEOF
from pronext.common.models import PadApk
latest = PadApk.objects.filter(status=PadApk.Status.PUBLISHED).order_by('-build_num').first()
if latest is None:
    print("ERR_NO_PUBLISHED")
elif latest.build_num != $BUILD_NUM:
    print(f"ERR_STALE: latest PUBLISHED is now build={latest.build_num}, not $BUILD_NUM. Re-run script.")
else:
    old = latest.is_paused
    latest.is_paused = $NEW_PAUSED
    latest.save(update_fields=['is_paused'])
    print(f"DONE {old}->{latest.is_paused} v{latest.version} build={latest.build_num}")
PYEOF
)

outln "$RESULT"

if echo "$RESULT" | grep -q "^DONE"; then
    NEW_STATE=$([ "$NEW_PAUSED" = "True" ] && echo "🛑 PAUSED" || echo "✅ ROLLING OUT")
    outln "APK rollout $ACTION applied — v${VERSION} (build ${BUILD_NUM}) is now: $NEW_STATE"
    outln "APK cache invalidated via post_save signal."
    outln "Container: $CONTAINER_NAME"
elif echo "$RESULT" | grep -q "^ERR_STALE"; then
    exit 2
elif echo "$RESULT" | grep -q "^ERR_NO_PUBLISHED"; then
    outln "No PUBLISHED PadApk found at apply time (was it un-published?). Aborting."
    exit 1
else
    outln "Apply failed with unexpected output. Inspect the message above."
    exit 1
fi

# ---- optional follow after start ------------------------------------------
if [ "$MODE" = "start" ] && [ "$FOLLOW" -eq 1 ]; then
    follow_progress "$BUILD_NUM" "$INTERVAL"
fi
