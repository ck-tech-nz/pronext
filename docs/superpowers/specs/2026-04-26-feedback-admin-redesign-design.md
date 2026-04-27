# Feedback Admin Redesign — Design

**Date:** 2026-04-26
**Scope:** Django admin custom page at `/admin/support/feedback/`
**Files involved:**
- `backend/pronext/support/models.py`
- `backend/pronext/support/admin.py`
- `backend/pronext/support/views.py`
- `backend/pronext/support/urls.py`
- `backend/pronext/support/templates/admin/support_list.html`

## Goal

Make the support feedback list page more useful for customer service:

1. Surface volume **trend** information so CS can sense when complaints are spiking and what type dominates.
2. Let admins **change a row's status inline** without opening the detail page.
3. **Merge `WebsiteFeedback`** into the same list (separate detail pages remain) so CS has one place to triage all incoming feedback.

## Non-goals

- Detail pages stay as they are: app-feedback rows continue to use the existing custom detail at `support:admin_feedback_detail`; website-feedback rows go to the standard Django admin change view.
- The public mobile-app `Feedback` API and the public website `WebsiteFeedback` POST API are unchanged on the wire.
- The existing `support_list.html` styling vocabulary (status badge colors, type colors, summary-card style) is reused; this is not a wholesale visual redesign. Specifically we do **not** migrate to the newer `stats-card` / `pca-*` vocabulary used by `user_stats.html` — that migration is left for a future pass so the support list and the existing support detail page stay visually consistent.

## Decisions taken (from brainstorming)

| Topic | Decision |
|---|---|
| Dashboard focus | Trend / volume |
| Time window | Switchable 7d / 30d / 90d |
| Chart style | Multi-line: Total + per-type, toggleable legend |
| Inline status interaction | Color-coded `<select>`, AJAX auto-save |
| WebsiteFeedback in list | Merged with App feedback into one paginated table |
| Source representation | Icon prefix in SN/ID column (`📱` / `🌐`); no dedicated Source column |
| Status enum | Single shared `Status` class on `support.models`; `WebsiteFeedback.status` rows renumbered via data migration |
| `ACKNOWLEDGED` integer | `-1` (side-state, doesn't pollute the 0..4 pipeline) |
| Trend chart lines | `Total` + `Bug` + `Feature` + `Sync` + `Performance` + `Website` (all website rows collapsed into one line) |
| Type/Subject filter | One dropdown grouped by source via `<optgroup>` |
| Rating | Star string (`★★★☆☆`) inline after the SN/ID for website rows |
| Total card | Bottom of the counts grid, smaller than status cards |
| Layout | Counts grid (left, ~40%) + trend chart (right, ~60%) in one row |

---

## Data model

### `support.models` — shared `Status` enum

Define `Status` at module scope and reference it from both models:

```python
# backend/pronext/support/models.py
from django.db import models

class Status(models.IntegerChoices):
    ACKNOWLEDGED = -1, "Acknowledged"
    NEW = 0, "New"
    IN_PROGRESS = 1, "In Progress"
    RESOLVED = 2, "Resolved"
    CLOSED = 3, "Closed"
    NEED_MORE_INFO = 4, "Need More Info"


class Feedback(models.Model):
    Status = Status                  # keep nested name for back-compat with callers
    # ... unchanged otherwise; status field already uses values 0..4
    status = models.SmallIntegerField(choices=Status.choices, default=Status.NEW)


class WebsiteFeedback(models.Model):
    Status = Status                  # same class; nested alias preserves callers
    # remove the existing inner Status class
    status = models.SmallIntegerField(choices=Status.choices, default=Status.NEW)
```

**Why a single class?** Both call sites already use `Feedback.Status.X` / `WebsiteFeedback.Status.X` — assigning the module-level `Status` to a class attribute keeps those references working without import changes.

### Renumbering migration for `WebsiteFeedback`

Old → new integer mapping:

| Label | Old value | New value |
|---|---:|---:|
| `NEW` | 0 | 0 (unchanged) |
| `ACKNOWLEDGED` | 1 | **-1** |
| `IN_PROGRESS` | 2 | **1** |
| `RESOLVED` | 3 | **2** |
| `CLOSED` | 4 | **3** |
| `NEED_MORE_INFO` | — | 4 (now available) |

Single Django migration:

1. `migrations.AlterField` on `Feedback.status` and `WebsiteFeedback.status` to update `choices`.
2. `migrations.RunPython` data migration that updates `WebsiteFeedback` rows in this order: `1 → -1`, `2 → 1`, `3 → 2`, `4 → 3`. **Move ACKNOWLEDGED (1→-1) first**, then cascade upward. Doing it the other way (4→3 first, then 3→2, …) cascades incorrectly: every step's target value gets re-caught by the next step's filter, and a row that started at `4` ends up at `-1`. Each step uses `update()` with an explicit `filter()` and runs inside the migration's atomic transaction.

The migration's `RunPython` step ships a `reverse_code` that applies the inverse mapping (so `migrate ... <previous>` works in dev). It is **not** safe to roll back in production after new rows have been created using the new numbering — those rows would map to wrong statuses. The deploy plan accepts that constraint.

### Touch points to update once `Status` is unified

- `backend/pronext/support/admin.py:192-200` — `mark_acknowledged` and `mark_resolved` actions on `WebsiteFeedbackAdmin`. The constants stay (`Status.ACKNOWLEDGED`, etc.), but now resolve to the shared class. No code change needed if the references are already through `WebsiteFeedback.Status`.
- `backend/pronext/support/views.py:50-53` — count metrics queries; will be replaced by the new combined view (see below).
- Any `is_resolved` properties — already correct.

---

## View layer

### Combined queryset

Both `Feedback` and `WebsiteFeedback` extend `models.Model`. We do **not** introduce a parent class or a polymorphic table — the view layer combines them in Python.

```python
# pseudocode
def admin_feedback_list(request):
    source = request.GET.get('source')        # '', 'app', 'website'
    status = request.GET.get('status')        # '', '-1'..'4'
    type_  = request.GET.get('type')          # 'app:0', 'web:bug', '' ...
    search = request.GET.get('search')
    window = request.GET.get('window', '7')   # '7' | '30' | '90'

    fb_qs = Feedback.objects.all()
    wf_qs = WebsiteFeedback.objects.all()

    if status:
        fb_qs = fb_qs.filter(status=int(status))
        wf_qs = wf_qs.filter(status=int(status))

    if source == 'app':    wf_qs = wf_qs.none()
    if source == 'website': fb_qs = fb_qs.none()

    if type_:
        kind, val = type_.split(':', 1)
        if kind == 'app':
            fb_qs = fb_qs.filter(type=int(val)); wf_qs = wf_qs.none()
        else:
            wf_qs = wf_qs.filter(subject=val); fb_qs = fb_qs.none()

    if search:
        fb_qs = fb_qs.filter(Q(description__icontains=search)
                             | Q(email__icontains=search)
                             | Q(user__username__icontains=search)
                             | Q(sn__icontains=search))
        wf_qs = wf_qs.filter(Q(message__icontains=search)
                             | Q(email__icontains=search)
                             | Q(name__icontains=search))

    rows = _merge_paginated(fb_qs, wf_qs, page=request.GET.get('page'), per_page=20)
    metrics = _compute_metrics(window=int(window))
    chart = _compute_chart_series(window=int(window))
    return render(...)
```

`_merge_paginated` strategy:

1. Annotate each queryset with a constant `source` field (`Value('app')` / `Value('website')`) and a `display_id` field (`F('sn')` for app, `Concat(Value('WF-'), F('id'))` for website) using `.annotate()` so SQL ordering on `created_at` works per-side.
2. Convert each side to a list of dicts with the columns the template needs (`source`, `display_id`, `created_at`, `type_label`, `type_color_key`, `from_label`, `description`, `tech_comment`, `status`, `rating` (None for app), `change_url`, `detail_url`).
3. Merge using a heap-merge on `created_at desc`, slice to the page window. For tens-of-thousands rows this is fast enough; if it ever grows past that we'd switch to a UNION ALL view, but YAGNI.

### Metrics

`_compute_metrics(window)` returns a dict keyed by `Status` value plus a `total` key:

```python
{
  Status.NEW:           23,
  Status.ACKNOWLEDGED:   5,
  Status.IN_PROGRESS:   31,
  Status.NEED_MORE_INFO: 8,
  Status.RESOLVED:      62,
  Status.CLOSED:        18,
  'total':             147,
}
```

**Window scoping rule:**
- The **status counts** (`NEW` / `ACKNOWLEDGED` / `IN_PROGRESS` / `NEED_MORE_INFO` / `RESOLVED` / `CLOSED`) are **all-time** — they reflect the current state of the pipeline regardless of when the row was created. A bug created 30 days ago that's still `IN_PROGRESS` today should still count toward the workload signal.
- The **`total`** card is the only window-scoped count: number of rows whose `created_at` falls inside the selected window. This is the "incoming volume" signal that pairs naturally with the trend chart.

Both sources are combined via two `.values('status').annotate(c=Count('id'))` queries plus a sum.

### Chart series

`_compute_chart_series(window)` returns:

```python
{
  'labels': ['2026-04-20', ..., '2026-04-26'],
  'series': {
    'total':       [10, 14, 22, 27, 20, 31, 26],
    'bug':         [4,  7, 11, 14, 11, 19, 16],
    'sync':        [1,  2,  3,  5,  4,  6,  5],
    'performance': [1,  1,  2,  2,  2,  3,  2],
    'feature':     [2,  2,  3,  3,  3,  4,  3],
    'website':     [3,  3,  5,  6,  4,  8,  6],
  }
}
```

- `total` = all rows in the window from both models, grouped by day on `created_at::date`.
- `bug` / `sync` / `performance` / `feature` = `Feedback` rows grouped by `type` (mapped to `Type.BUG / .SYNC_PROBLEM / .PERFORMANCE_ISSUE / .FEATURE_REQUEST`). `Other` is intentionally not a separate line; it's still in `total`.
- `website` = all `WebsiteFeedback` rows in the window, grouped by day. We do not break out by `subject` here — chosen during brainstorming because website "subjects" are mostly inquiry buckets (Pricing, Service) rather than bug categories.
- For 30d / 90d windows the granularity stays daily; the chart just gets denser.

Implementation: two `TruncDate('created_at')` GROUP BY queries (one per model), zero-fill missing days client-side or server-side.

### Inline status update endpoint

New URL & view:

```python
# urls.py
path('api/update-status/', update_status, name='admin_update_status'),

# views.py
@staff_member_required
@require_http_methods(["POST"])
def update_status(request):
    source = request.POST.get('source')        # 'app' | 'website'
    obj_id = int(request.POST.get('id'))
    new_status = int(request.POST.get('status'))

    if new_status not in Status.values:
        return JsonResponse({'ok': False, 'error': 'invalid status'}, status=400)

    Model = Feedback if source == 'app' else WebsiteFeedback
    obj = get_object_or_404(Model, id=obj_id)
    obj.status = new_status
    obj.save(update_fields=['status', 'updated_at'])
    return JsonResponse({'ok': True})
```

Closing behavior: when `new_status == Status.CLOSED`, the JS does **not** prompt for a final conclusion (we accept that admins must use the detail page if they want to record a conclusion). The existing detail-page popup that requires a conclusion before closing is retained; this is a deliberate trade-off so the inline action stays one click. Documented in the template comment.

CSRF: the existing Django admin already provides a CSRF token on the page; the JS reads it from the cookie or hidden input and adds it to each AJAX call.

---

## Template / front-end

### `support_list.html` — structural changes

The existing file already inherits `admin/change_list.html` and ships its own CSS block. Updates:

1. Replace the current 5-card flex row with a 2-column grid: 6 status cards + 1 muted "Total" card spanning both columns at the bottom. Status cards use the colors that already exist for badges (`#1976d2`, `#9c27b0`, `#f57f17`, `#c62828`, `#2e7d32`, `#455a64`).
2. Add a chart container (`<div id="trend-chart">` + a Vanilla SVG built by the same JS we add for AJAX). Place counts and chart in a 2-column outer grid (≥1100px viewport; collapses to single column below that).
3. Update the filter bar: add a `Source` `<select>`; replace the current Type `<select>` with the grouped Type/Subject control.
4. Update the table header to: `SN / ID | Type | From | Description | Tech | Status`. Drop `#`, `Visible`, and the original `Status` badge column header (status badge becomes the editable `<select>`).
5. Update each `<tr>`:
   - SN/ID cell: source emoji prefix (`📱` for app, `🌐` for website), then bold ID, then ★ rating for website rows. The whole cell gets `title="Created: {{ row.created_at|date:'Y-m-d H:i' }}"` for the hover tooltip.
   - Type cell: keep the existing `feedback-type type-bug/feature/...` classes for app rows; for website rows use the same color vocabulary mapped by subject (`bug` and `feature` reuse existing colors; `pricing`/`product`/`service` get a generic gray badge `type-other`; `support` reuses `type-performance` blue; `general` reuses `type-other`).
   - Status cell: `<select class="inline-status" data-source="..." data-id="..." data-status="...">` with all 6 `Status` options. Background color comes from a small CSS rule keyed by `data-status` so the select reflects state visually. Native `<select>` dropdown for simplicity (decision A from brainstorm).
6. Each row's content cells (everything except the Status `<select>`) link to that row's detail URL — app rows continue to point at `support:admin_feedback_detail`; website rows point at `admin:support_websitefeedback_change`. The Status cell does not navigate (clicking the `<select>` opens it). Either: (a) wrap each non-Status cell in an `<a>` so only those cells are clickable; or (b) keep the existing row `onclick="window.location='...'"` pattern and add `event.stopPropagation()` on the Status cell's pointer events so opening the dropdown doesn't bubble up. Option (a) is preferred because it keeps middle-click / cmd-click "open in new tab" working naturally.

### Chart rendering

No new JS dependencies. We render the chart as a hand-rolled inline SVG generated in plain JavaScript:

- Reads the chart series JSON from a `<script type="application/json" id="chart-data">` element rendered server-side.
- Builds polylines, axis labels, grid lines, and a legend with toggleable lines.
- Window switcher (`7d / 30d / 90d` buttons) updates the URL query (`?window=30`) and reloads the page (full server fetch) — keeps things simple and lets the metrics cards refresh too.
- Legend toggling is purely client-side: clicking a legend item hides/shows that polyline.

Decision rationale: a tiny custom SVG renderer (~100 LOC) avoids pulling in Chart.js / D3 just for one screen, and the existing project doesn't already depend on a charting library. If we later add more charts elsewhere we can reconsider.

### Inline status `<select>` behavior

```js
// support_list.html — inline script
document.querySelectorAll('select.inline-status').forEach(sel => {
  sel.addEventListener('change', async (e) => {
    const original = sel.dataset.status;
    const next = sel.value;
    sel.disabled = true;
    try {
      const res = await fetch('/admin/support/api/update-status/', {
        method: 'POST',
        headers: { 'X-CSRFToken': csrfToken(), 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ source: sel.dataset.source, id: sel.dataset.id, status: next }),
      });
      const data = await res.json();
      if (!data.ok) throw new Error(data.error || 'unknown');
      sel.dataset.status = next;
      applyStatusColor(sel, next);   // updates background to match status color
      toast('Status updated');
    } catch (err) {
      sel.value = original;
      toast('Failed to update: ' + err.message, 'error');
    } finally {
      sel.disabled = false;
    }
  });
});
```

Toast uses a single floating `<div>` that fades in/out — no library.

---

## URL & permissions

| Path | Old | New |
|---|---|---|
| `/admin/support/feedback/` | `admin_feedback_list` (Feedback only) | unchanged URL; view rewritten to merge sources |
| `/admin/support/feedback/<id>/` | `admin_feedback_detail` (Feedback) | unchanged |
| `/admin/support/api/update-status/` | — | new, `@staff_member_required`, POST-only |
| `/admin/support/websitefeedback/<id>/change/` | Django admin builtin | unchanged |

All endpoints remain `@staff_member_required` (existing decorator).

---

## Testing

### Unit tests

- `tests/test_status_migration.py` — synthetic `WebsiteFeedback` rows in each old status; run the migration; assert new integer values match the table above.
- `tests/test_views_admin_list.py`:
  - Default view returns merged rows ordered by `created_at desc`.
  - `?source=app` filters out website rows (and vice-versa).
  - `?status=-1` returns only `ACKNOWLEDGED` rows from both sources.
  - `?type=app:0` returns only `Feedback` Bug rows; `?type=web:pricing` returns only `WebsiteFeedback` Pricing rows.
  - Search hits across `Feedback.description` / `email` / `username` and `WebsiteFeedback.message` / `email` / `name`.
  - Window param `7|30|90` controls metric/chart computation.
- `tests/test_update_status_endpoint.py`:
  - POST with valid source+id+status → 200, object updated.
  - Invalid status (e.g. `999`) → 400.
  - Missing object → 404.
  - Non-staff user → 302/403.
  - CSRF protection: missing token → 403.
- `tests/test_chart_series.py` — given fixed rows, returns expected daily buckets including zero-fills for empty days.

### Manual / integration

- Open `/admin/support/feedback/` with mixed app + website data; verify counts, chart, table, source icons, ratings, tooltips.
- Change a row's status via the dropdown; reload page; value persists; counts on top reflect change.
- Switch `7d / 30d / 90d`; chart and counts update.
- Click an app row → existing detail page; click a website row → Django admin change page.
- Resize down to 800px viewport → counts/chart stack vertically; table scrolls horizontally.

---

## Migration & rollout plan

1. **Code change** — add shared `Status`, edit both models, write `0010_unify_status.py` migration with renumbering RunPython, ship view + template + JS together.
2. **Pre-deploy backup** — standard pg18 backup snapshot before applying the data migration.
3. **Deploy** — single deploy; migration is fast (a handful of `UPDATE`s on a small table).
4. **Verify** in staging first: load `/admin/support/feedback/`, exercise inline status changes, confirm the chart matches the row counts.
5. **Communicate** to admin staff that the WebsiteFeedback `status` column has been renumbered (only relevant if they had bookmarks / saved filters using raw integer values, which is unlikely).

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Data migration runs against bad data and silently corrupts statuses | Migration is wrapped in a transaction; tests cover the mapping; pre-deploy DB backup. |
| Mobile-app `Feedback` API consumers see a status they don't recognise | **Verified safe (2026-04-26):** the Flutter app has no native Feedback rendering — it delegates to the H5 WebView. The H5 pages [Support.vue](../../h5/src/pages/support/Support.vue) and [ReportDetail.vue](../../h5/src/pages/support/ReportDetail.vue) render the label from the server's `status_display` field (which `get_status_display()` populates correctly for all 6 values, including `ACKNOWLEDGED=-1`), and the tag color switch falls through to the neutral `'default'` Vant style for any unknown integer. The "add comment" guard at `ReportDetail.vue:279` correctly leaves the reply box open when status is `ACKNOWLEDGED`. No app or H5 changes required. |
| Combining two querysets in Python paginates poorly with very large N | Current volumes are <10k rows total; heap-merge over two `created_at desc`-ordered lists is O(n). Reassess if volumes grow 10×. |
| Inline status dropdown changes are easy to mis-click | Toast confirms; admin can immediately re-pick to undo. We accept no confirm modal in exchange for one-click speed. |

## Open questions

None — all called out during brainstorm and resolved.

## Out of scope (future work)

- Sortable table columns (currently fixed-sort by `created_at desc`).
- Saved filter presets per admin user.
- Per-status SLA aging indicators (would belong to a future "urgency" iteration; user picked trend over urgency in the brainstorm).
- Real-time updates (currently the page fetches on full load).
