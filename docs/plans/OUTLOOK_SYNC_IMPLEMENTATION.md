# Outlook/Office365 日历双向同步实现计划

> **认证模式**: SPA (Single Page Application) + PKCE，无需 Client Secret
> **同步架构**: Go Syncer (类似 ics_syncer)
> **当前状态**: Phase 1 已完成，Phase 3.5 (Go Syncer) 待实现

## 概述

为 Pronext 添加 Outlook/Office365 日历双向同步功能。作为 **SaaS 服务提供商**，Pronext 代替用户（成千上万客户）与 Microsoft Graph API 交互，需要：

- 多租户 Azure AD 应用注册
- 为每个用户存储和管理 OAuth2 token
- 可扩展的增量同步策略（Delta Query）

## 架构设计

```
┌─────────────────┐                 ┌──────────────────────────────────────┐
│  用户 A 设备     │──OAuth──┐       │          Django Backend              │
├─────────────────┤         │       │  ┌────────────────────────────────┐  │
│  用户 B 设备     │──OAuth──┼──────▶│  │  每用户存储 outlook_credential   │  │
├─────────────────┤         │       │  │  定时 Delta Query 增量同步       │  │
│  用户 C 设备     │──OAuth──┘       │  └───────────────┬────────────────┘  │
└─────────────────┘                 └──────────────────┼───────────────────┘
                                                       │ Graph API (代用户请求)
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │       Microsoft Graph API            │
                                    │  /users/{user-id}/calendars          │
                                    │  (使用用户的 delegated token)          │
                                    └──────────────────────────────────────┘
```

### 大规模实时通知方案

对于成千上万客户的实时通知，有两种主要策略：

| 方案                 | 优点                   | 缺点                                        | 适用场景             |
| -------------------- | ---------------------- | ------------------------------------------- | -------------------- |
| **Webhook 订阅**     | 真正实时推送           | 每个用户需单独订阅，最长3天需续订，管理复杂 | 用户量 < 1000        |
| **Delta Query 轮询** | 实现简单，无需公网端点 | 有延迟（5-15分钟）                          | 用户量 > 1000 (推荐) |

**推荐方案**: Delta Query 增量轮询 (Cloudflare Worker)

- Cloudflare Worker 定时触发批量轮询（与 Google Calendar 同步一致）
- 使用 `deltaLink` 只获取变更的事件
- 按优先级/活跃度分批处理用户
- 注意：项目未启用 Celery，使用 Cloudflare Worker 替代

## 实现阶段

### Phase 1: 核心 OAuth2 和只读同步

**目标**: 实现 Outlook OAuth2 认证，从 Outlook 拉取事件到本地

#### 1.1 数据模型变更

**文件**: `server/pronext/calendar/models.py`

在 `SyncedCalendar` 模型添加字段:

```python
outlook_credential = models.JSONField(null=True, blank=True)
outlook_credential_expired_at = models.DateTimeField(null=True, blank=True)
outlook_calendar_id = models.CharField(max_length=200, blank=True)
outlook_subscription_id = models.CharField(max_length=200, blank=True)
outlook_subscription_expiry = models.DateTimeField(null=True, blank=True)
```

#### 1.2 创建 OutlookCalendar 类

**新文件**: `server/pronext/calendar/sync_outlook.py`

参考 `sync.py` 中的 `GoogleCalendar` 类模式 (行 100-258):

- OAuth2 认证 (MSAL 库)
- Token 自动刷新
- Graph API 请求封装
- `get_events()` / `add_event()` / `update_event()` / `delete_event()`

```python
class OutlookCalendar:
    CLIENT_ID = "..."  # Azure AD App (SPA mode, no secret needed)
    SCOPES = ["Calendars.ReadWrite", "offline_access", "openid", "User.Read"]
    GRAPH_URL = "https://graph.microsoft.com/v1.0"
```

#### 1.3 API 端点

**文件**: `server/pronext/calendar/viewset_app.py`

新增 actions (参考 `google()` 方法, 行 87-109):

- `POST /synced/outlook` - 添加 Outlook 日历
- `GET /synced/outlook_calendars` - 获取用户的 Outlook 日历列表

#### 1.4 同步逻辑

**文件**: `server/pronext/calendar/options.py`

- 添加 `_get_oc()` 函数 (参考 `_get_gc()`, 行 34-49)
- 添加 `_outlook_token_flushed()` 回调
- 修改 `sync_calendar()` 支持 Outlook 类型

---

### Phase 2: 双向同步

**目标**: 本地事件变更推送到 Outlook

#### 2.1 事件 CRUD 集成

**文件**: `server/pronext/calendar/options.py`

修改函数支持 Outlook:

- `add_event()` - 创建事件时同步到 Outlook
- `update_event()` - 更新事件时同步到 Outlook
- `delete_event()` - 删除事件时同步到 Outlook

#### 2.2 RRULE 转换

**文件**: `server/pronext/calendar/sync_outlook.py`

- `_convert_rrule_to_graph()` - RRULE -> Graph recurrence
- `_convert_graph_to_rrule()` - Graph recurrence -> RRULE

**文件**: `server/pronext/calendar/sync_event.py`

添加 `SyncEvent.from_outlook_event()` 类方法

#### 2.3 Celery 任务

**文件**: `server/pronext/calendar/tasks.py`

```python
@celery_app.task
def flush_outlook_token_task(n=1, all=False, id=None):
    flush_outlook_token(n=n, all=all, id=id)
```

---

### Phase 3: Delta Query 增量同步 (大规模方案)

**目标**: 高效同步成千上万用户的日历变更

#### 3.1 Delta Query 原理

Microsoft Graph 提供 Delta Query 机制：

- 首次请求返回所有事件 + `deltaLink`
- 后续使用 `deltaLink` 只返回变更的事件
- 无需逐个创建 webhook 订阅

```python
# 首次同步
GET /me/calendars/{id}/events/delta

# 响应包含
{
    "value": [...所有事件...],
    "@odata.deltaLink": "https://graph.microsoft.com/v1.0/.../delta?$deltatoken=xxx"
}

# 后续增量同步 (只返回变更)
GET {deltaLink}
```

#### 3.2 数据模型扩展

**文件**: `server/pronext/calendar/models.py`

```python
# SyncedCalendar 新增字段
outlook_delta_link = models.TextField(blank=True, help_text="Delta Query link for incremental sync")
outlook_last_sync = models.DateTimeField(null=True, blank=True)
outlook_sync_priority = models.IntegerField(default=0, help_text="Higher = sync more frequently")
```

#### 3.3 批量同步 Celery 任务

**文件**: `server/pronext/calendar/tasks.py`

```python
@celery_app.task
def batch_sync_outlook_calendars():
    """
    每 5 分钟运行，批量同步活跃用户的 Outlook 日历
    - 优先同步最近有操作的用户
    - 按 outlook_sync_priority 排序
    - 每批处理 100 个用户
    """
    calendars = SyncedCalendar.objects.filter(
        calendar_type=SyncedCalendar.Type.OUTLOOK,
        is_active=True,
        outlook_credential__isnull=False,
    ).order_by('-outlook_sync_priority', 'outlook_last_sync')[:100]

    for synced in calendars:
        sync_single_outlook_calendar.delay(synced.id)

@celery_app.task
def sync_single_outlook_calendar(synced_calendar_id):
    """使用 Delta Query 同步单个日历"""
    synced = SyncedCalendar.objects.get(id=synced_calendar_id)
    oc = OutlookCalendar(synced.outlook_credential)

    if synced.outlook_delta_link:
        # 增量同步
        result = oc.get_events_delta(synced.outlook_delta_link)
    else:
        # 首次全量同步
        result = oc.get_events_delta()

    # 保存新的 deltaLink
    synced.outlook_delta_link = result.get('delta_link')
    synced.outlook_last_sync = timezone.now()
    synced.save()

    # 处理变更事件...
```

#### 3.4 OutlookCalendar Delta 方法

```python
def get_events_delta(self, delta_link: str = None) -> dict:
    """增量获取事件变更"""
    if delta_link:
        # 使用已有的 deltaLink
        result = self._request_raw('GET', delta_link)
    else:
        # 首次请求
        endpoint = f"/me/calendars/{self.calendar_id}/events/delta"
        result = self._request('GET', endpoint)

    events = result.get('value', [])
    next_link = result.get('@odata.nextLink')  # 分页
    delta_link = result.get('@odata.deltaLink')  # 保存用于下次

    # 处理分页
    while next_link:
        page = self._request_raw('GET', next_link)
        events.extend(page.get('value', []))
        next_link = page.get('@odata.nextLink')
        delta_link = page.get('@odata.deltaLink', delta_link)

    return {
        'events': events,
        'delta_link': delta_link,
        'removed': [e['id'] for e in events if e.get('@removed')]
    }
```

#### 3.5 Celery Beat 配置

```python
CELERY_BEAT_SCHEDULE = {
    'batch-sync-outlook': {
        'task': 'pronext.calendar.tasks.batch_sync_outlook_calendars',
        'schedule': crontab(minute='*/5'),  # 每 5 分钟
    },
    'flush-outlook-tokens': {
        'task': 'pronext.calendar.tasks.flush_outlook_token_task',
        'schedule': crontab(minute='*/10'),  # 每 10 分钟
    },
}
```

---

### Phase 3.5: Go Outlook Syncer 增量同步 (推荐方案)

> 创建独立的 `outlook_syncer` 服务，与 `ics_syncer` 完全解耦，便于独立部署、调试和迭代。

#### 3.5.1 架构概述

创建独立的 Go 服务 (`server/scripts/go/outlook_syncer/`)：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Linux Server                                        │
│                                                                             │
│  ┌─────────────────────────────┐    ┌─────────────────────────────────┐    │
│  │  ics_syncer (不改动)         │    │  outlook_syncer (新增)           │    │
│  │                             │    │                                 │    │
│  │  calendar_type:             │    │  calendar_type=2 only           │    │
│  │  - 0: ICS Link              │    │                                 │    │
│  │  - 1: Google Calendar       │    │  1. 轮询 Django API              │    │
│  │  - 3-7: iCloud, Cozi, etc.  │    │  2. Microsoft Graph API 同步     │    │
│  │                             │    │  3. Delta Query 增量获取          │    │
│  └──────────────┬──────────────┘    └────────────────┬────────────────┘    │
│                 │                                    │                      │
└─────────────────┼────────────────────────────────────┼──────────────────────┘
                  │                                    │
                  └────────────────┬───────────────────┘
                                   ▼
                    ┌──────────────────────────────────────┐
                    │       Django Backend                 │
                    │  GET  /get_outlook_calendars/        │
                    │  POST /sync_outlook_calendar/        │
                    └──────────────────────────────────────┘
```

**独立服务的优势**：

- 🔧 **低耦合** - 不影响现有 ics_syncer 的稳定性
- 🚀 **独立部署** - 可以单独启停、重启、升级
- 🔍 **方便调试** - 独立日志，问题定位更清晰
- 📦 **独立迭代** - Outlook 功能变更不影响 ICS 同步

#### 3.5.2 目录结构

```text
server/scripts/go/
├── ics_syncer/             # 现有 ICS syncer (重命名自 syncer/)
│   ├── main.go
│   ├── config.go
│   ├── syncer.go
│   ├── http.go
│   ├── types.go
│   └── ics_syncer.service
│
└── outlook_syncer/         # 新增 Outlook syncer
    ├── main.go             # 入口、信号处理
    ├── config.go           # 配置、环境变量
    ├── syncer.go           # 核心同步逻辑
    ├── outlook.go          # Microsoft Graph API 调用
    ├── types.go            # 数据结构定义
    └── outlook_syncer.service
```

#### 3.5.3 Go 实现

##### `outlook_syncer/main.go`

```go
package main

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
    "time"
)

var VERSION = "1.0.0"

func main() {
    cfg := LoadConfig()

    fmt.Printf("[--------------------------------%s Start Outlook Syncer--------------------------------]\n", time.Now().Format(time.RFC3339))
    fmt.Printf("[VERSION] %s\n", VERSION)

    syncer := NewSyncer(cfg)

    // 优雅关闭：捕获 SIGINT/SIGTERM
    ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
    defer cancel()

    syncer.Run(ctx)

    fmt.Println("[SHUTDOWN] Graceful shutdown complete")
}
```

##### `outlook_syncer/config.go`

```go
package main

import (
    "flag"
    "os"
    "time"
)

type Config struct {
    APIDomain   string
    AuthHeader  string
    Concurrency int
    Interval    time.Duration
}

func LoadConfig() *Config {
    cfg := &Config{
        APIDomain:   getEnv("API_DOMAIN", "https://api.pronextusa.com"),
        AuthHeader:  os.Getenv("SYNC_AUTH_HEADER"),
        Concurrency: 5,
        Interval:    5 * time.Minute,
    }

    flag.IntVar(&cfg.Concurrency, "c", cfg.Concurrency, "Concurrency")
    flag.DurationVar(&cfg.Interval, "i", cfg.Interval, "Interval between sync rounds")
    flag.Parse()

    return cfg
}

func (c *Config) CheckURL() string {
    return c.APIDomain + "/get_outlook_calendars/"
}

func (c *Config) SyncURL() string {
    return c.APIDomain + "/sync_outlook_calendar/"
}

func getEnv(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}
```

##### `outlook_syncer/types.go`

```go
package main

// OutlookCalendar 从 Django API 获取的日历信息
type OutlookCalendar struct {
    ID                int    `json:"id"`
    Name              string `json:"name"`
    Email             string `json:"email"`
    AccessToken       string `json:"access_token"`
    CalendarID        string `json:"calendar_id"`
    DeltaLink         string `json:"delta_link"`
    RelUserIDs        []int  `json:"rel_user_ids"`
}

// OutlookEvent Microsoft Graph API 返回的事件
type OutlookEvent struct {
    ID                   string           `json:"id"`
    Subject              string           `json:"subject"`
    Start                OutlookDateTime  `json:"start"`
    End                  OutlookDateTime  `json:"end"`
    IsAllDay             bool             `json:"isAllDay"`
    Body                 OutlookBody      `json:"body"`
    Location             OutlookLocation  `json:"location"`
    Recurrence           *OutlookRecur    `json:"recurrence,omitempty"`
    LastModifiedDateTime string           `json:"lastModifiedDateTime"`
    Removed              *OutlookRemoved  `json:"@removed,omitempty"`
}

type OutlookDateTime struct {
    DateTime string `json:"dateTime"`
    TimeZone string `json:"timeZone"`
}

type OutlookBody struct {
    ContentType string `json:"contentType"`
    Content     string `json:"content"`
}

type OutlookLocation struct {
    DisplayName string `json:"displayName"`
}

type OutlookRecur struct {
    Pattern OutlookPattern `json:"pattern"`
    Range   OutlookRange   `json:"range"`
}

type OutlookPattern struct {
    Type           string   `json:"type"`
    Interval       int      `json:"interval"`
    DaysOfWeek     []string `json:"daysOfWeek,omitempty"`
    DayOfMonth     int      `json:"dayOfMonth,omitempty"`
}

type OutlookRange struct {
    Type      string `json:"type"`
    StartDate string `json:"startDate"`
    EndDate   string `json:"endDate,omitempty"`
}

type OutlookRemoved struct {
    Reason string `json:"reason"`
}

// DeltaResponse Microsoft Graph Delta Query 响应
type DeltaResponse struct {
    Value     []OutlookEvent `json:"value"`
    NextLink  string         `json:"@odata.nextLink,omitempty"`
    DeltaLink string         `json:"@odata.deltaLink,omitempty"`
}

// SyncStats 同步统计
type SyncStats struct {
    Total   int
    Success int
    Skipped int
    Failed  int
}
```

##### `outlook_syncer/syncer.go`

```go
package main

import (
    "context"
    "fmt"
    "sync"
    "time"
)

type Syncer struct {
    config *Config
}

func NewSyncer(cfg *Config) *Syncer {
    return &Syncer{config: cfg}
}

func (s *Syncer) Run(ctx context.Context) {
    round := 1
    for {
        fmt.Printf("\n>>>>>>>>> Round %d checking...\n", round)
        s.processRound(ctx)

        select {
        case <-ctx.Done():
            fmt.Println("[SHUTDOWN] Received signal, exiting...")
            return
        case <-time.After(s.config.Interval):
        }
        round++
    }
}

func (s *Syncer) processRound(ctx context.Context) {
    calendars, err := FetchOutlookCalendars(s.config.CheckURL(), s.config.AuthHeader)
    if err != nil {
        fmt.Printf("[API ERROR] %v\n", err)
        return
    }

    if len(calendars) == 0 {
        fmt.Println("[INFO] No Outlook calendars to sync")
        return
    }

    var wg sync.WaitGroup
    var mu sync.Mutex
    stats := &SyncStats{}
    sem := make(chan struct{}, s.config.Concurrency)

    for _, cal := range calendars {
        wg.Add(1)
        go func(cal OutlookCalendar) {
            defer wg.Done()
            sem <- struct{}{}
            defer func() { <-sem }()
            s.processCalendar(cal, stats, &mu)
        }(cal)
    }

    wg.Wait()
    fmt.Printf("[SUMMARY] Total: %d, Success: %d, Skipped: %d, Failed: %d\n",
        stats.Total, stats.Success, stats.Skipped, stats.Failed)
}

func (s *Syncer) processCalendar(cal OutlookCalendar, stats *SyncStats, mu *sync.Mutex) {
    mu.Lock()
    stats.Total++
    mu.Unlock()

    // 调用 Microsoft Graph API
    result, statusCode, err := FetchOutlookEvents(cal.AccessToken, cal.CalendarID, cal.DeltaLink)
    if err != nil {
        fmt.Printf("[ERROR] %s: %v (status: %d)\n", cal.Email, err, statusCode)
        mu.Lock()
        stats.Failed++
        mu.Unlock()
        return
    }

    // 无变更时跳过
    if len(result.Value) == 0 && cal.DeltaLink != "" {
        fmt.Printf("[SKIP] %s: no changes\n", cal.Email)
        mu.Lock()
        stats.Skipped++
        mu.Unlock()
        return
    }

    // 分离删除和更新的事件
    var removed []string
    var events []OutlookEvent
    for _, e := range result.Value {
        if e.Removed != nil {
            removed = append(removed, e.ID)
        } else {
            events = append(events, e)
        }
    }

    // 同步到 Django
    err = SyncToBackend(s.config.SyncURL(), s.config.AuthHeader, cal, events, removed, result.DeltaLink)
    if err != nil {
        fmt.Printf("[SYNC ERROR] %s: %v\n", cal.Email, err)
        mu.Lock()
        stats.Failed++
        mu.Unlock()
        return
    }

    fmt.Printf("[OK] %s: %d events, %d removed\n", cal.Email, len(events), len(removed))
    mu.Lock()
    stats.Success++
    mu.Unlock()
}
```

##### `outlook_syncer/outlook.go`

```go
package main

import (
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"
)

const GraphAPIBaseURL = "https://graph.microsoft.com/v1.0"

// FetchOutlookEvents 从 Microsoft Graph API 获取事件 (支持 Delta Query)
func FetchOutlookEvents(accessToken, calendarID, deltaLink string) (*DeltaResponse, int, error) {
    var url string
    if deltaLink != "" {
        url = deltaLink
    } else {
        // 首次同步：获取过去6个月的事件
        timeMin := time.Now().AddDate(0, -6, 0).Format("2006-01-02T15:04:05")
        url = fmt.Sprintf("%s/me/calendars/%s/events/delta?$filter=start/dateTime ge '%s'",
            GraphAPIBaseURL, calendarID, timeMin)
    }

    client := &http.Client{Timeout: 30 * time.Second}
    result := &DeltaResponse{}

    for url != "" {
        req, _ := http.NewRequest("GET", url, nil)
        req.Header.Set("Authorization", "Bearer "+accessToken)
        req.Header.Set("Prefer", `outlook.body-content-type="text"`)

        resp, err := client.Do(req)
        if err != nil {
            return nil, 0, err
        }

        if resp.StatusCode != 200 {
            resp.Body.Close()
            return nil, resp.StatusCode, fmt.Errorf("Graph API returned %d", resp.StatusCode)
        }

        body, _ := io.ReadAll(resp.Body)
        resp.Body.Close()

        var page DeltaResponse
        if err := json.Unmarshal(body, &page); err != nil {
            return nil, 200, err
        }

        result.Value = append(result.Value, page.Value...)
        result.DeltaLink = page.DeltaLink
        url = page.NextLink // 继续分页，或为空退出
    }

    return result, 200, nil
}
```

##### `outlook_syncer/http.go`

```go
package main

import (
    "bytes"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"
)

// FetchOutlookCalendars 从 Django 获取待同步的 Outlook 日历列表
func FetchOutlookCalendars(url, auth string) ([]OutlookCalendar, error) {
    req, _ := http.NewRequest("GET", url, nil)
    req.Header.Set("Authorization", auth)

    client := &http.Client{Timeout: 10 * time.Second}
    resp, err := client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    if resp.StatusCode != 200 {
        return nil, fmt.Errorf("API returned %d", resp.StatusCode)
    }

    var result struct {
        Calendars []OutlookCalendar `json:"calendars"`
    }
    body, _ := io.ReadAll(resp.Body)
    if err := json.Unmarshal(body, &result); err != nil {
        return nil, err
    }

    return result.Calendars, nil
}

// SyncToBackend 将同步结果发送到 Django
func SyncToBackend(url, auth string, cal OutlookCalendar, events []OutlookEvent, removed []string, deltaLink string) error {
    payload := map[string]interface{}{
        "id":           cal.ID,
        "rel_user_ids": cal.RelUserIDs,
        "events":       events,
        "removed":      removed,
        "delta_link":   deltaLink,
    }

    jsonData, _ := json.Marshal(payload)
    req, _ := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
    req.Header.Set("Authorization", auth)
    req.Header.Set("Content-Type", "application/json")

    client := &http.Client{Timeout: 30 * time.Second}
    resp, err := client.Do(req)
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    if resp.StatusCode != 200 {
        body, _ := io.ReadAll(resp.Body)
        return fmt.Errorf("sync failed: %d - %s", resp.StatusCode, string(body))
    }

    return nil
}
```

#### 3.5.4 Django 后端更新

**文件**: `server/pronext/calendar/views.py`

新增独立的 API 端点，与 ICS syncer 的端点分离：

##### 新增 `get_outlook_calendars()`: 获取待同步的 Outlook 日历

```python
def get_outlook_calendars(request):
    """供 outlook_syncer 调用，获取待同步的 Outlook 日历列表"""
    synceds = SyncedCalendar.objects.filter(
        calendar_type=2,  # Outlook only
        is_active=True,
        google_credit__isnull=False
    )
    result = []

    for synced in synceds:
        # 检查 token 是否即将过期 (5分钟内)，自动刷新
        if synced.google_credit_expired_at:
            if synced.google_credit_expired_at < timezone.now() + timedelta(minutes=5):
                outlook = OutlookCalendar(synced.google_credit, synced.email)
                new_token = outlook.flush_token()
                if new_token:
                    synced.google_credit = new_token
                    synced.google_credit_expired_at = timezone.now() + timedelta(hours=1)
                    synced.save()

        result.append({
            'id': synced.id,
            'name': synced.name,
            'email': synced.email,
            'access_token': synced.google_credit.get('access_token'),
            'calendar_id': synced.outlook_calendar_id,
            'delta_link': synced.outlook_delta_link or '',
            'rel_user_ids': list(synced.rel_users.values_list('id', flat=True)),
        })

    return JsonResponse({'calendars': result})
```

##### 新增 `sync_outlook_calendar()`: 处理 Outlook 同步结果

```python
def sync_outlook_calendar(request):
    """供 outlook_syncer 调用，处理同步结果"""
    data = json.loads(request.body)
    synced_id = data.get('id')
    events = data.get('events', [])
    removed_ids = data.get('removed', [])
    delta_link = data.get('delta_link')
    rel_user_ids = data.get('rel_user_ids', [])

    synced = SyncedCalendar.objects.get(id=synced_id)

    # 更新 deltaLink
    if delta_link:
        synced.outlook_delta_link = delta_link
        synced.save(update_fields=['outlook_delta_link'])

    # 处理删除的事件
    if removed_ids:
        Event.objects.filter(
            synced_calendar=synced,
            synced_id__in=removed_ids
        ).delete()

    # 处理新增/更新的事件
    for outlook_event in events:
        sync_single_outlook_event(synced, outlook_event, rel_user_ids)

    return JsonResponse({'status': 'ok', 'synced': len(events), 'removed': len(removed_ids)})
```

##### URL 配置

```python
# pronext_server/urls.py
urlpatterns = [
    # ... 现有路由 ...
    path('get_outlook_calendars/', views.get_outlook_calendars),
    path('sync_outlook_calendar/', views.sync_outlook_calendar),
]
```

#### 3.5.5 数据模型更新

**文件**: `server/pronext/calendar/models.py`

```python
class SyncedCalendar(models.Model):
    # ... 现有字段 ...

    # Outlook 特定字段
    outlook_calendar_id = models.CharField(max_length=200, blank=True)
    outlook_delta_link = models.TextField(blank=True, help_text="Delta Query link for incremental sync")

    # 注意: 复用 google_credit 字段存储 Outlook token
    # google_credit = models.JSONField(null=True, blank=True)  # 存储 {access_token, refresh_token}
    # google_credit_expired_at = models.DateTimeField(null=True, blank=True)
```

#### 3.5.6 部署

##### systemd 服务文件: `outlook_syncer.service`

```ini
[Unit]
Description=Pronext Outlook Calendar Syncer
After=network.target

[Service]
Type=simple
User=pronext
WorkingDirectory=/opt/pronext
ExecStart=/opt/pronext/outlook_syncer
Restart=always
RestartSec=10
Environment=API_DOMAIN=https://api.pronextusa.com
Environment=SYNC_AUTH_HEADER=Bearer xxx

[Install]
WantedBy=multi-user.target
```

##### 编译和部署

```bash
# 编译
cd server/scripts/go/outlook_syncer
go build -o outlook_syncer .

# 部署到服务器
scp outlook_syncer user@server:/opt/pronext/
scp outlook_syncer.service user@server:/etc/systemd/system/

# 启用并启动服务
sudo systemctl daemon-reload
sudo systemctl enable outlook_syncer
sudo systemctl start outlook_syncer

# 查看日志
sudo journalctl -u outlook_syncer -f
```

---

### Phase 4: 冲突解决和测试

#### 4.1 冲突解决策略

基于 `lastModifiedDateTime` 的最后写入胜出:

```python
def resolve_conflict(local_event, remote_event) -> str:
    # 比较 updated_at vs lastModifiedDateTime
    return 'local' if local_modified > remote_modified else 'remote'
```

#### 4.2 测试

**新文件**: `server/pronext/calendar/tests/test_outlook_sync.py`

- RRULE 转换测试
- Token 刷新测试
- 同步流程测试
- 冲突解决测试

---

## 关键文件清单

| 操作 | 文件路径                                                                |
| ---- | ----------------------------------------------------------------------- |
| 新建 | `server/pronext/calendar/sync_outlook.py`                       |
| 新建 | `server/pronext/calendar/migrations/00XX_add_outlook_fields.py` |
| 新建 | `server/pronext/calendar/tests/test_outlook_sync.py`            |
| 修改 | `server/pronext/calendar/models.py`                             |
| 修改 | `server/pronext/calendar/options.py`                            |
| 修改 | `server/pronext/calendar/viewset_app.py`                        |
| 修改 | `server/pronext/calendar/viewset_serializers.py`                |
| 修改 | `server/pronext/calendar/sync_event.py`                         |
| 修改 | `server/pronext/calendar/tasks.py`                              |
| 修改 | `server/pronext/calendar/views.py`                              |
| 修改 | `server/requirements.txt`                                       |

## 依赖

```
msal==1.31.0  # Microsoft Authentication Library
```

## 前置条件：Azure AD 多租户应用注册

### 步骤 1: 创建 Azure 账户

1. 访问 https://portal.azure.com
2. 使用 Microsoft 账户登录（可以是个人账户）
3. 如果没有订阅，创建免费订阅

### 步骤 2: 注册应用

1. 在 Azure Portal 搜索 "App registrations" (应用注册)
2. 点击 "New registration" (新注册)
3. 填写信息：
   - **Name**: `Pronext Calendar`
   - **Supported account types**: 选择 **"Accounts in any organizational directory and personal Microsoft accounts"** (多租户 + 个人账户)
   - **Redirect URI**: 先跳过，注册后配置
4. 点击 "Register"

### 步骤 3: 配置 SPA 平台 (重要!)

> ⚠️ **使用 SPA 模式**: 我们采用 Single Page Application (SPA) 模式，使用 PKCE 流程进行认证，**无需 Client Secret**。

1. 在应用页面，点击 "Authentication" (身份验证)
2. 点击 "Add a platform" → 选择 **"Single-page application"**
3. 配置 Redirect URI:
   - 开发环境: `http://localhost:5173/outlook_authed/`
   - 生产环境: `https://h5.pronextusa.com/outlook_authed/`
4. 点击 "Configure"

**SPA 模式优势**:

- 无需管理 Client Secret（不会过期、不会泄露）
- 使用 PKCE (Proof Key for Code Exchange) 更安全
- 前端直接完成 token 交换，无需后端中转

### 步骤 4: 配置 API 权限

1. 在应用页面，点击 "API permissions"
2. 点击 "Add a permission" → "Microsoft Graph" → "Delegated permissions"
3. 添加以下权限：
   - `Calendars.ReadWrite` (读写日历)
   - `offline_access` (刷新 token)
   - `openid` (用户身份)
   - `User.Read` (基本资料)
4. 点击 "Add permissions"
5. **不需要** 点击 "Grant admin consent" (每个用户自己授权)

### 步骤 5: 获取配置值

从 "Overview" 页面获取：

- **Application (client) ID**: 这是 `OUTLOOK_CLIENT_ID`

> 📝 **注意**: SPA 模式不需要 Client Secret！

### 环境变量配置

在 `server/.env` 添加：

```bash
OUTLOOK_CLIENT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
OUTLOOK_REDIRECT_URI=http://localhost:5173/outlook_authed/
# 注意: SPA 模式无需 OUTLOOK_CLIENT_SECRET
```

## 当前实施状态

### ✅ Phase 1 已完成 (2026-01-28)

分支: `feature/outlook-calendar-oauth`

#### 后端实施文件

| 文件 | 状态 | 说明 |
| ---- | ---- | ---- |
| `pronext/calendar/outlook_sync.py` | ✅ 新建 | OutlookCalendar 类，Microsoft Graph API 交互 |
| `pronext/calendar/views.py` | ✅ 修改 | 添加 `outlook_authed()` OAuth 回调 |
| `pronext/calendar/viewset_app.py` | ✅ 修改 | 添加 `outlook()` 和 `get_outlook_auth_code()` action |
| `pronext/calendar/viewset_serializers.py` | ✅ 修改 | 添加 Outlook 序列化器 |
| `pronext/calendar/options.py` | ✅ 修改 | `sync_calendar()` 支持 Outlook，添加 `_get_outlook()` |
| `pronext_server/urls.py` | ✅ 修改 | 添加 `/outlook_authed/` 路由 |

#### 前端实施文件

| 文件 | 状态 | 说明 |
| ---- | ---- | ---- |
| `src/pages/synced/Outlook.vue` | ✅ 新建 | Outlook 日历选择页面 |
| `src/managers/synced.js` | ✅ 修改 | 添加 `useSyncedOutlook()` composable |
| `src/router.js` | ✅ 修改 | 添加 `/synced/:device_id/outlook` 路由 |
| `src/pages/synced/Add.vue` | ✅ 修改 | Outlook 入口跳转到 OAuth 页面 |

#### 关键设计决策

1. **复用 `google_credit` 字段**: Outlook token 存储在现有的 `google_credit` JSONField 中（Google 和 Outlook token 结构相同）
2. **前端驱动 Token 交换**: 与 Google Calendar 采用相同的"前端驱动+轮询"架构
3. **无需新增依赖**: 使用 `requests` 库直接调用 Microsoft Graph API，无需 MSAL

---

## 测试指南

### 前置条件

1. Azure AD 应用注册已完成（参考文档末尾的步骤，使用 SPA 模式）
2. `.env` 配置已设置:
   ```bash
   OUTLOOK_CLIENT_ID=577793e1-1aa2-4e62-8606-24ae649833a4
   OUTLOOK_REDIRECT_URI=http://localhost:5173/outlook_authed/
   # 注意: SPA 模式无需 CLIENT_SECRET
   ```

### 测试 1: 后端代码验证

```bash
# 进入后端目录
cd server

# 验证模块导入
.venv/bin/python3 -c "
import sys
sys.path.insert(0, '.')
import django
import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'pronext_server.settings')
django.setup()

from pronext.calendar.outlook_sync import OutlookCalendar
from pronext.calendar.options import sync_calendar, _get_outlook
print('✅ 所有模块导入成功')
"
```

### 测试 2: OAuth 流程测试

#### 2.1 启动后端服务

```bash
cd server
source .venv/bin/activate
python3 manage.py runserver 0.0.0.0:8008
```

#### 2.2 启动前端服务

```bash
cd vue
npm run dev
```

#### 2.3 测试 OAuth 流程

1. 在浏览器访问: `http://localhost:5173/synced/{device_id}/add`
2. 点击 "Outlook, Hotmail or Live"
3. 选择同步方式（One-way / Two-way）
4. 点击 "Next" 按钮
5. 在弹出的 Microsoft 登录页面完成授权
6. 授权成功后会自动返回，显示日历列表
7. 点击要同步的日历

#### 2.4 验证 OAuth 回调

```bash
# 查看 Django 日志，确认 OAuth 回调正常
# 应该能看到类似的日志:
# "GET /outlook_authed/?code=xxx&state=xxx HTTP/1.1" 200
```

### 测试 3: 日历同步测试

#### 3.1 检查数据库记录

```bash
cd server
source .venv/bin/activate
python3 manage.py shell
```

```python
from pronext.calendar.models import SyncedCalendar

# 查看已同步的 Outlook 日历
outlooks = SyncedCalendar.objects.filter(calendar_type=2)
for o in outlooks:
    print(f"ID: {o.id}, Email: {o.email}, Name: {o.name}")
    print(f"  Has credential: {bool(o.google_credit)}")
    print(f"  Expired at: {o.google_credit_expired_at}")
```

#### 3.2 手动触发同步

```python
from pronext.calendar.options import sync_calendar
from pronext.calendar.models import SyncedCalendar

synced = SyncedCalendar.objects.filter(calendar_type=2).first()
if synced:
    result = sync_calendar(synced, [synced.user_id])
    print(f"同步结果: {result}")
```

#### 3.3 检查同步的事件

```python
from pronext.calendar.models import Event

events = Event.objects.filter(synced_calendar_id=synced.id)
print(f"同步的事件数量: {events.count()}")
for e in events[:5]:
    print(f"  - {e.title} ({e.start_at or e.start_date})")
```

### 测试 4: Token 刷新测试

```python
from pronext.calendar.outlook_sync import OutlookCalendar
from pronext.calendar.models import SyncedCalendar

synced = SyncedCalendar.objects.filter(calendar_type=2).first()
if synced and synced.google_credit:
    outlook = OutlookCalendar(
        credit=synced.google_credit,
        email=synced.email
    )

    # 手动刷新 token
    result = outlook.flush_token()
    print(f"Token 刷新结果: {result}")
```

### 测试 5: API 端点测试

使用 curl 或 Postman 测试:

```bash
# 获取授权码（需要先完成 OAuth 流程）
curl -X POST http://localhost:8008/app-api/calendar/device/{device_id}/synced/get_outlook_auth_code \
  -H "Authorization: Bearer {jwt_token}" \
  -H "Content-Type: application/json" \
  -d '{"state": "your_state_string"}'

# 添加 Outlook 日历
curl -X POST http://localhost:8008/app-api/calendar/device/{device_id}/synced/outlook \
  -H "Authorization: Bearer {jwt_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "synced_style": 1,
    "email": "calendar_id_from_microsoft",
    "name": "My Outlook Calendar",
    "outlook_credit": {
      "access_token": "...",
      "refresh_token": "...",
      "expires_in": 3600
    },
    "color": "#0078D4"
  }'
```

### 常见问题排查

#### Q1: OAuth 回调后页面空白

**原因**: 前端轮询未获取到授权码

**检查**:
1. Django 日志中是否有 `/outlook_authed/` 请求
2. Redis 是否正常运行: `redis-cli ping`
3. 检查 state 参数是否匹配

#### Q2: Token 交换失败 (400 错误)

**原因**: Azure AD 配置问题

**检查**:

1. `OUTLOOK_CLIENT_ID` 是否正确
2. `OUTLOOK_REDIRECT_URI` 是否与 Azure Portal 中 SPA 平台配置一致
3. 确认 Azure AD 应用配置为 **SPA 平台**（不是 Web 平台）

#### Q3: 获取日历列表为空

**原因**: 权限不足或 token 无效

**检查**:
1. Azure AD 应用是否有 `Calendars.Read` 权限
2. access_token 是否有效
3. 用户的 Outlook 账户中是否有日历

#### Q4: 同步后事件不显示

**原因**: Beat 系统未触发刷新

**检查**:
```python
from pronext.common.models import Beat
from django.core.cache import cache

# 检查 Beat 标志
device_id = 123
key = f":1:beat1:{device_id}"
print(cache.get(key))
```

### 运行自动化测试

```bash
cd server
source .venv/bin/activate

# 运行 Outlook 同步相关测试
python3 manage.py test pronext.calendar.tests.test_outlook_sync -v 2

# 运行所有日历测试
python3 manage.py test pronext.calendar -v 2
```

## Google vs Outlook 功能差距分析 (2026-02-06)

> 以下对比基于 Google Calendar 同步的完整实现，列出 Outlook 同步尚缺失或不完整的功能。

### 功能对比总表

| # | 功能 | Google | Outlook | 差距等级 | 状态 |
|---|------|--------|---------|---------|------|
| 1 | 基本 CRUD (add/update/delete) | ✅ 完整 | ✅ 基本完成 | - | ✅ |
| 2 | 双向同步 - 普通事件 | ✅ | ✅ | - | ✅ |
| 3 | 双向同步 - 重复事件 (recurrence) | ✅ 发送 RRULE | ✅ 发送 Graph recurrence | - | ✅ 2026-02-06 |
| 4 | 更新重复事件 - THIS (单个例外) | ✅ 创建 override | ✅ 删除 instance + 新建 | - | ✅ 2026-02-06 |
| 5 | 更新重复事件 - AND_FUTURE (截断+新建) | ✅ 新建+修改 RRULE | ✅ update_recurrence + 新建 | - | ✅ 2026-02-06 |
| 6 | 删除重复事件 - THIS (单个例外) | ✅ 删除 instance | ✅ delete_repeat_this_event | - | ✅ 2026-02-06 |
| 7 | 删除重复事件 - AND_FUTURE (截断 UNTIL) | ✅ 修改 RRULE | ✅ update_recurrence | - | ✅ 2026-02-06 |
| 8 | Token 批量刷新 (flush_outlook_token) | ✅ flush_google_token | ✅ flush_outlook_token | - | ✅ 2026-02-06 |
| 9 | delete_event 自动 token 刷新 | ✅ (通过 exec) | ✅ 401 重试 | - | ✅ 2026-02-06 |
| 10 | RRULE → Graph recurrence 反向转换 | N/A | ✅ _convert_rrule_to_graph | - | ✅ 2026-02-06 |
| 11 | Go Syncer Delta Query | N/A (Cloudflare) | ✅ 已修复 | - | ✅ |
| 12 | Django-side sync (sync_calendar) | ✅ 完整 | ✅ 基本可用 | - | ✅ |
| 13 | Etag 变更检测 | ✅ | ✅ | - | ✅ |
| 14 | Beat 通知 | ✅ | ✅ | - | ✅ |
| 15 | Category 自动创建 | ✅ | ✅ | - | ✅ |

### 详细差距说明

#### 🔴 Gap 3: 双向同步不发送 recurrence 到 Outlook

**现状**: `outlook_sync.py` 的 `_build_event_body()` 只发送 `subject`, `isAllDay`, `start`, `end`，不包含 recurrence。

**影响**: 从 App 创建重复事件时，Outlook 只会收到单次事件，不会创建重复系列。

**修复方案**:
- 实现 `_convert_rrule_to_graph()`: 将 RRULE 字符串转为 Microsoft Graph `recurrence` 对象
- 在 `_build_event_body()` 中加入 `recurrence` 字段
- 在 `add_event()` 和 `update_event()` 中传入 `recurrence` 参数

**文件**: `server/pronext/calendar/outlook_sync.py`

#### 🔴 Gap 4: 更新重复事件 THIS 模式未实现

**现状**: `options.py` 的 `update_event()` 在 `change_type == THIS` 时，只对 Google 创建 override instance。Outlook 无操作。

**影响**: 用户在 App 中修改重复事件的单个实例时，Outlook 不会同步。

**修复方案**:
- Microsoft Graph API 支持 PATCH `/me/events/{instance-id}` 修改单个实例
- 需要先获取 recurring event 的 instances，找到对应日期的 instance ID
- 或者使用 `POST /me/events` 创建 exception (类似 Google 的 recurringEventId 方式)

**文件**: `server/pronext/calendar/options.py`, `outlook_sync.py`

#### 🔴 Gap 6: 删除重复事件 THIS 模式未实现

**现状**: `options.py` 的 `delete_event()` 在 `change_type == THIS` 时，只对 Google 调用 `delete_repeat_this_event()`。Outlook 无操作。

**影响**: 用户在 App 中删除重复事件的单个实例时，Outlook 不会同步。

**修复方案**:
- Microsoft Graph API: `DELETE /me/events/{instance-id}` 删除特定 instance
- 需要在 `OutlookCalendar` 中实现 `delete_repeat_this_event()` 方法

**文件**: `server/pronext/calendar/options.py`, `outlook_sync.py`

#### 🟡 Gap 5 & 7: AND_FUTURE 模式未实现

**现状**: Outlook 没有类似 Google 的 `recurringEventId` + `UNTIL` 修改机制。

**修复方案**:
- AND_FUTURE 更新: PATCH series master 的 recurrence range (修改 UNTIL)，然后 POST 新 event with recurrence
- AND_FUTURE 删除: PATCH series master 的 recurrence range (修改 UNTIL)
- 实现 `OutlookCalendar.update_recurrence()` 方法

**文件**: `server/pronext/calendar/options.py`, `outlook_sync.py`

#### 🟡 Gap 8: 缺少独立的 Outlook Token 刷新任务

**现状**: Google 有 `flush_google_token()` 可以批量刷新即将过期的 token。Outlook 只在 Go syncer 请求日历列表时刷新。

**影响**: 如果用户从 App 操作事件时 token 已过期，`_make_request()` 会尝试刷新一次，但没有主动刷新机制。

**修复方案**:
- 实现 `flush_outlook_token()` 函数，类似 `flush_google_token()`
- 由外部定时任务调用 (Cloudflare Worker 或 Go service)

**文件**: `server/pronext/calendar/options.py`

#### 🟡 Gap 9: delete_event 不经过 _make_request

**现状**: `OutlookCalendar.delete_event()` 直接使用 `requests.delete()` 而非 `_make_request()`，不会自动刷新 token。

**修复方案**: 改为使用 `_make_request('DELETE', url)` 并处理 204 响应。

**文件**: `server/pronext/calendar/outlook_sync.py`

#### 🔴 Gap 10: RRULE → Graph recurrence 反向转换

**现状**: 已有 `_convert_outlook_recurrence()` (Graph → RRULE)，但没有反向转换 `_convert_rrule_to_graph()` (RRULE → Graph)。

**影响**: 无法将 App 中的重复事件发送到 Outlook。

**修复方案**: 实现 `_convert_rrule_to_graph(rrule_str, start_date)` 函数。

**文件**: `server/pronext/calendar/outlook_sync.py`

---

### 开发任务清单 (按优先级排序)

| 序号 | 任务 | 优先级 | 预估复杂度 | 涉及文件 |
|------|------|--------|-----------|----------|
| T1 | 实现 `_convert_rrule_to_graph()` | P0 | 中 | `outlook_sync.py` |
| T2 | `_build_event_body()` 支持 recurrence | P0 | 低 | `outlook_sync.py` |
| T3 | `add_event()` 传入 recurrence 参数 | P0 | 低 | `options.py` |
| T4 | `delete_event` 使用 `_make_request` | P1 | 低 | `outlook_sync.py` |
| T5 | 实现 `flush_outlook_token()` | P1 | 低 | `options.py` |
| T6 | 实现 Outlook `update_recurrence()` | P1 | 中 | `outlook_sync.py` |
| T7 | update_event THIS 模式支持 Outlook | P1 | 高 | `options.py`, `outlook_sync.py` |
| T8 | delete_event THIS 模式支持 Outlook | P1 | 高 | `options.py`, `outlook_sync.py` |
| T9 | update_event AND_FUTURE 模式支持 Outlook | P2 | 高 | `options.py`, `outlook_sync.py` |
| T10 | delete_event AND_FUTURE 模式支持 Outlook | P2 | 中 | `options.py`, `outlook_sync.py` |

---

## 风险和挑战

| 风险                     | 影响 | 缓解措施                          |
| ------------------------ | ---- | --------------------------------- |
| RRULE/Graph 格式转换复杂 | 高   | 完善转换函数，覆盖复杂重复模式    |
| Token 刷新失败           | 中   | 重试逻辑，用户通知                |
| Webhook 不可靠           | 中   | 定时轮询作为 fallback             |
| Azure AD 多租户支持      | 中   | 使用 /common 端点支持所有账户类型 |
