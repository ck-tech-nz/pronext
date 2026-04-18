# Calendar 模块架构演进计划

## 概述

本文档讨论 Calendar 模块从"后端代理"架构向"Pad 端直连"架构的演进方案。此讨论独立于具体的数据源实现 (iCloud/Google/Outlook)。

### 核心约束

**Backend 必须保持 Source of Truth**，原因：

1. **H5 移动端** - Vue WebView 应用，与 Pad 功能几乎一致，依赖 Backend API
2. **多 Pad 设备** - 同一用户可能有多个 Pad，需要数据同步
3. **数据备份** - 用户数据需要在服务端持久化
4. **权限控制** - rel_user 权限体系在 Backend 实现

---

## 当前架构 (方案 A)

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Pad App   │     │  H5 (Vue)   │     │ Mobile App  │
│  (Kotlin)   │     │  (WebView)  │     │  (Flutter)  │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │ GET /events       │ GET /events       │ Config
       │                   │                   │
       └───────────────────┼───────────────────┘
                           ▼
              ┌────────────────────────────────────────────────────┐
              │                  Django Backend                    │
              │  ┌──────────────────────────────────────────────┐  │
              │  │              PostgreSQL                      │  │
              │  │           (Source of Truth)                  │  │
              │  └──────────────────────────────────────────────┘  │
              │                       ▲                            │
              │                       │ Write parsed events        │
              │  ┌────────────────────┴─────────────────────────┐  │
              │  │              sync_calendar()                 │  │
              │  │         (ICS parse + event storage)          │  │
              │  └────────────────────▲─────────────────────────┘  │
              └───────────────────────┼────────────────────────────┘
                                      │ POST ICS content
                                      │
       ┌──────────────────────────────┼──────────────────────────────┐
       │                              │                              │
       ▼                              │                              ▼
┌─────────────────┐          ┌───────┴────────┐          ┌─────────────────┐
│  Go ICS Syncer  │          │                │          │ Cloudflare      │
│  (Linux Server) │          │                │          │ Workers         │
│                 │          │                │          │                 │
│ - Poll ICS URLs │          │                │          │ - Google OAuth2 │
│ - SHA256 check  │          │                │          │ - Cron trigger  │
│ - Concurrent DL │          │                │          │                 │
└────────┬────────┘          │                │          └────────┬────────┘
         │                   │                │                   │
         ▼                   │                │                   ▼
    ┌─────────┐              │                │              ┌─────────┐
    │  ICS    │              │                │              │ Google  │
    │  URLs   │              │                │              │ Calendar│
    └─────────┘              │                │              └─────────┘
                             │                │
                      (Outlook/iCloud TBD)
```

### 当前同步方式

| 数据源               | 同步执行者         | 技术栈      | 状态      |
| -------------------- | ------------------ | ----------- | --------- |
| **ICS 订阅**         | Go Syncer (Linux)  | Go + HTTP   | ✅ 运行中 |
| **Google Calendar**  | Cloudflare Workers | JS + OAuth2 | ✅ 运行中 |
| **Outlook Calendar** | -                  | -           | 📝 计划中 |
| **iCloud CalDAV**    | -                  | -           | 📝 计划中 |

### Go ICS Syncer 工作流程

```
server/scripts/go/syncer/

1. 从 Django API 获取 SyncedCalendar 列表
2. 并发下载各个 ICS URL
3. 计算 SHA256，检测内容变化
4. 变化时 POST ICS 内容到 Django sync_calendar()
5. Django 解析 ICS，写入 Event/Category 到 PostgreSQL
```

### 特点

| 维度       | 说明                                                   |
| ---------- | ------------------------------------------------------ |
| 数据流向   | 外部源 → Go/Workers → Django API → PostgreSQL → Pad/H5 |
| 轮询位置   | Go (Linux) / Cloudflare Workers                        |
| ICS 解析   | Django (Python icalendar)                              |
| 存储位置   | PostgreSQL (唯一)                                      |
| Pad 复杂度 | 低 (只调 API)                                          |
| 离线能力   | 无                                                     |

> **注意**: Celery 目前未启用，同步任务由独立的 Go 进程和 Cloudflare Workers 处理。

---

## 演进架构 (方案 B)

### 核心思想

- **Backend 仍是 Source of Truth** - 所有数据最终存储在 PostgreSQL
- **Pad 增加本地缓存** - Room DB 存储事件，支持离线查看
- **部分源由 Pad 直连** - 减轻 Backend 轮询压力
- **Pad 同步后上报 Backend** - 保持数据一致性

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Client Layer                                   │
├─────────────────────────────┬─────────────────────┬─────────────────────────┤
│         Pad App             │      H5 (Vue)       │      Mobile App         │
│  ┌───────────────────────┐  │                     │                         │
│  │      Room DB          │  │  (No local storage) │   (Config only)         │
│  │  ┌─────────────────┐  │  │                     │                         │
│  │  │ cached_events   │  │  │                     │                         │
│  │  │ synced_calendars│  │  │                     │                         │
│  │  │ credentials     │  │  │                     │                         │
│  │  └─────────────────┘  │  │                     │                         │
│  └───────────┬───────────┘  │                     │                         │
│              │              │                     │                         │
│   ┌──────────┴──────────┐   │                     │                         │
│   │ CalDAV/ICS Client   │   │                     │                         │
│   │ (Direct connect)    │   │                     │                         │
│   └──────────┬──────────┘   │                     │                         │
└──────────────┼──────────────┴─────────────────────┴─────────────────────────┘
               │ Direct (ICS/iCloud)
               │                    ┌─────────────────────────────────────────┐
               │                    │           Data Flow Legend              │
               ▼                    │  ────── API request                     │
┌──────────────────────────┐        │  ══════ Data upload                     │
│    External Sources      │        │  ─ ─ ─  Heartbeat                       │
│  ┌────┐ ┌────┐ ┌──────┐  │        └─────────────────────────────────────────┘
│  │ICS │ │iCld│ │Google│  │
│  └──┬─┘ └──┬─┘ └───┬──┘  │
└─────┼──────┼───────┼─────┘
      │      │       │
      │      │       │ (Still via Backend)
      │      │       ▼
      │      │    ┌────────────────────────────────────────────────────────┐
      │      │    │                  Django Backend                        │
      │      │    │  ┌──────────────────────────────────────────────────┐  │
      │      │    │  │              PostgreSQL                          │  │
      │      │    │  │         (Source of Truth)                        │  │
      │      │    │  │  ┌─────────────────┐  ┌────────────────────────┐ │  │
      └──────┴────┼──┼─▶│ synced_calendar │  │        event           │ │  │
   Pad uploads    │  │  └─────────────────┘  └────────────────────────┘ │  │
                  │  └──────────────────────────────────────────────────┘  │
                  │                          │                             │
                  │                          │ Heartbeat / API             │
                  │                          ▼                             │
                  │  ┌──────────────────────────────────────────────────┐  │
                  │  │  Response to Pad / H5:                           │  │
                  │  │  - events (full or incremental)                  │  │
                  │  │  - credentials (encrypted)                       │  │
                  │  │  - sync flags                                    │  │
                  │  └──────────────────────────────────────────────────┘  │
                  └────────────────────────────────────────────────────────┘
```

---

## 数据流详解

### 场景 1: ICS 订阅 (Pad 直连)

```
[Initial Setup - via Mobile App]
User ──Add ICS URL──▶ Mobile App ──POST──▶ Backend (save SyncedCalendar)

[Pad gets config]
Pad ──Heartbeat──▶ Backend ──return SyncedCalendar (with ICS URL)──▶ Pad
Pad ──save to Room DB──▶ Local

[Pad direct sync]
Pad ──HTTP GET──▶ ICS Server ──.ics file──▶ Pad
Pad ──parse ICS──▶ Room DB (local cache)
Pad ──POST /events/sync──▶ Backend (upload changes)
Backend ──save to PostgreSQL──▶ (Source of Truth)

[H5 view]
H5 ──GET /events──▶ Backend ──return events──▶ H5
```

### 场景 2: iCloud CalDAV (Pad 直连)

```
[Initial Setup - via Mobile App]
User ──enter Apple ID + App Password──▶ Mobile App
Mobile App ──POST credential──▶ Backend (encrypted storage)

[Pad gets credential]
Pad ──Heartbeat──▶ Backend ──return credential (encrypted)──▶ Pad
Pad ──decrypt & save to Room DB──▶ Local

[Pad direct sync]
Pad ──CalDAV PROPFIND/REPORT──▶ iCloud ──events──▶ Pad
Pad ──parse ICS, expand RRULE──▶ Room DB
Pad ──POST /events/sync──▶ Backend (upload changes)

[H5 view]
H5 ──GET /events──▶ Backend ──return events──▶ H5
```

### 场景 3: Google Calendar (Backend 代理)

```
[OAuth2 - requires Backend]
Due to OAuth2 token refresh complexity, Google Calendar stays in Backend proxy mode.

[Sync flow]
Cloudflare Workers ──poll──▶ Google API ──events──▶ PostgreSQL
Pad ──Heartbeat (should_refresh_event=true)──▶ triggers fetch
Pad ──GET /events──▶ Backend ──return events──▶ Room DB
```

---

## 数据模型

### Backend (Django)

```python
# 现有模型，无需大改
class SyncedCalendar(models.Model):
    # ... 现有字段 ...

    # 新增: 标记是否由 Pad 直连
    sync_mode = models.CharField(
        max_length=20,
        choices=[
            ('backend', 'Backend Proxy'),  # Google, Outlook
            ('pad_direct', 'Pad Direct'),  # ICS, iCloud
        ],
        default='backend'
    )

class Event(models.Model):
    # ... 现有字段 ...

    # 新增: 追踪来源
    synced_by = models.CharField(
        max_length=20,
        choices=[
            ('backend', 'Backend'),
            ('pad', 'Pad Device'),
        ],
        default='backend'
    )
    external_etag = models.CharField(max_length=200, blank=True)  # 用于增量同步
```

### Pad (Room DB)

```kotlin
@Entity(tableName = "synced_calendars")
data class SyncedCalendarEntity(
    @PrimaryKey val id: Long,
    val name: String,
    val color: String,
    val calendarType: Int,  // ICS, ICLOUD, GOOGLE, OUTLOOK
    val syncMode: String,   // "backend" or "pad_direct"

    // 直连模式需要的字段
    val icsUrl: String?,
    val credentialJson: String?,  // 加密存储

    // 同步状态
    val lastSyncAt: Long?,
    val syncStatus: String,  // ACTIVE, SYNCING, ERROR, CREDENTIAL_EXPIRED
    val ctag: String?,  // iCloud 日历级别变更标记
)

@Entity(tableName = "events")
data class EventEntity(
    @PrimaryKey val id: String,
    val syncedCalendarId: Long,

    // 事件基础字段
    val title: String,
    val description: String?,
    val startAt: Long?,
    val endAt: Long?,
    val startDate: String?,  // all-day event
    val endDate: String?,
    val rrule: String?,
    val location: String?,

    // 同步追踪
    val externalUid: String?,  // iCloud UID, Google ID
    val etag: String?,
    val lastModifiedAt: Long,
    val syncStatus: String,  // SYNCED, PENDING_UPLOAD, CONFLICT
)
```

---

## API 设计

### 新增: Pad 上报同步结果

```
POST /app-api/calendar/device/{device_id}/events/sync

Request:
{
    "synced_calendar_id": 123,
    "events": [
        {
            "action": "upsert",  // or "delete"
            "external_uid": "icloud-event-uid-xxx",
            "etag": "xxx",
            "title": "Meeting",
            "start_at": "2025-01-30T10:00:00Z",
            "end_at": "2025-01-30T11:00:00Z",
            "rrule": null
        }
    ],
    "sync_completed_at": "2025-01-30T09:00:00Z"
}

Response:
{
    "success": true,
    "conflicts": [],  // 如有冲突，返回需要处理的事件
    "server_events": []  // 服务端有但 Pad 没有的事件 (其他设备创建的)
}
```

### Heartbeat 扩展

```
POST /app-api/heartbeat/

Response (扩展):
{
    // 现有字段...

    "calendar_sync": {
        "should_full_sync": false,
        "calendars_updated": [123, 456],  // 需要重新同步的日历 ID
        "credentials_updated": [123],      // 凭证有更新的日历 ID
    }
}
```

---

## 多端数据一致性

### 问题

当 Pad 直连同步后，H5 和其他 Pad 如何获取最新数据？

### 解决方案: Backend 作为同步枢纽

```
┌─────────┐        ┌─────────┐        ┌─────────┐
│  Pad A  │        │ Backend │        │  Pad B  │
└────┬────┘        └────┬────┘        └────┬────┘
     │                  │                  │
     │  1. Direct sync  │                  │
     │     to iCloud    │                  │
     │                  │                  │
     │  2. POST sync    │                  │
     │─────────────────▶│                  │
     │                  │                  │
     │                  │  3. Save to PG   │
     │                  │  Set beat flag   │
     │                  │                  │
     │                  │  4. Heartbeat    │
     │                  │◀─────────────────│
     │                  │                  │
     │                  │  5. Response:    │
     │                  │  should_refresh  │
     │                  │─────────────────▶│
     │                  │                  │
     │                  │  6. GET /events  │
     │                  │◀─────────────────│
     │                  │                  │
     │                  │  7. Return data  │
     │                  │─────────────────▶│
     │                  │                  │
```

### H5 同步

H5 无本地存储，每次打开都从 Backend 获取最新数据：

```
H5 ──GET /events──▶ Backend ──return latest events (incl. Pad uploaded)──▶ H5
```

---

## 边缘场景处理

### 1. 设备长时间离线

| 数据源  | 凭证类型              | 过期风险      | 处理方式     |
| ------- | --------------------- | ------------- | ------------ |
| ICS     | URL (无认证)          | 无            | 直接重新获取 |
| iCloud  | App-Specific Password | 永不过期      | 直接重新同步 |
| Google  | OAuth2 refresh_token  | 6个月未用过期 | 提示重新授权 |
| Outlook | OAuth2 refresh_token  | 90天未用过期  | 提示重新授权 |

### 2. 设备重置 / 新设备

```
[Recovery flow after Room DB cleared]

1. Login -> get JWT
2. Heartbeat -> Backend returns:
   - synced_calendars (with credentials)
   - should_full_sync = true
3. Pad saves config to Room DB
4. For pad_direct mode:
   - Use credentials to sync directly from source
5. For backend mode:
   - GET /events from Backend
6. Write data to Room DB
7. Recovery complete (5-20 sec)
```

### 3. 切换账号

```kotlin
// 每用户独立数据库
fun getDatabaseName(userId: Long) = "calendar_user_$userId.db"

fun onLogout(userId: Long) {
    // 关闭并删除当前用户数据库
    database.close()
    context.deleteDatabase(getDatabaseName(userId))
}

fun onLogin(userId: Long) {
    // 创建/打开新用户数据库
    database = Room.databaseBuilder(
        context,
        CalendarDatabase::class.java,
        getDatabaseName(userId)
    ).build()
}
```

### 4. 冲突处理

当 Pad A 和 Pad B 同时修改同一事件：

```kotlin
// Backend 冲突检测
fun handleEventSync(padEvent: EventDTO, userId: Long): SyncResult {
    val serverEvent = eventRepo.findByExternalUid(padEvent.externalUid)

    if (serverEvent == null) {
        // 新事件，直接保存
        return SyncResult.Created(eventRepo.save(padEvent.toEntity()))
    }

    if (serverEvent.lastModifiedAt > padEvent.lastModifiedAt) {
        // 服务端更新，Pad 需要拉取
        return SyncResult.Conflict(serverEvent)
    }

    // Pad 更新，保存到服务端
    return SyncResult.Updated(eventRepo.save(padEvent.toEntity()))
}
```

---

## 迁移策略

### Phase 0: 准备工作 (不改变现有行为)

- [ ] Pad 端添加 Room DB Schema
- [ ] 实现 EventDao, SyncedCalendarDao
- [ ] 添加 ICS 解析库 (ical4j)

### Phase 1: 双写验证

- [ ] Pad 从 Backend API 获取 events 后，同时写入 Room DB
- [ ] UI 仍读取 API 返回值
- [ ] 后台对比 Room vs API 数据一致性
- [ ] 验证 Room 查询性能

### Phase 2: 切换 Pad 读取源

- [ ] Pad UI 改为读取 Room DB
- [ ] Backend API 仍作为数据来源 (写入 Room)
- [ ] 确保查询结果与之前一致

### Phase 3: ICS 直连 (低风险试点)

- [ ] 新增 SyncedCalendar.sync_mode 字段
- [ ] ICS 类型日历标记为 `pad_direct`
- [ ] Pad 直接 HTTP GET ICS → 解析 → Room
- [ ] Pad POST sync 上报 Backend
- [ ] 验证 H5 可以看到 Pad 同步的数据

### Phase 4: iCloud 直连 (可选)

- [ ] 实现 Pad 端 CalDAV 客户端
- [ ] iCloud 类型日历标记为 `pad_direct`
- [ ] 凭证通过 Heartbeat 下发

### Phase 5: 全面推广

- [ ] 监控 Backend 负载下降
- [ ] 评估是否需要迁移 Google/Outlook

---

## OAuth2 与 PKCE 决策分析

### 为什么 Google/Outlook 保持 Backend 代理模式

Google 和 Outlook 使用 OAuth2 认证，与 iCloud 的 App-Specific Password (Basic Auth) 有本质区别：

```
┌────────────────────────────────────────────────────────────────────────────┐
│                     OAuth2 vs Basic Auth Comparison                         │
├────────────────────────────────────┬───────────────────────────────────────┤
│           OAuth2 (Google/Outlook)  │      Basic Auth (iCloud)              │
├────────────────────────────────────┼───────────────────────────────────────┤
│  client_id     (public, in APK)    │  username  (Apple ID)                 │
│  client_secret (MUST be secret)    │  password  (App-Specific Password)    │
│  access_token  (short-lived, 1h)   │                                       │
│  refresh_token (long-lived)        │  (no expiration)                      │
├────────────────────────────────────┼───────────────────────────────────────┤
│  Token refresh requires:           │  Each request uses:                   │
│  client_id + client_secret +       │  username + password                  │
│  refresh_token                     │  (can be stored on device)            │
└────────────────────────────────────┴───────────────────────────────────────┘
```

**核心问题**: `client_secret` 不能嵌入 APK

- APK 可以被反编译，任何嵌入的 secret 都可能泄露
- 一旦 `client_secret` 泄露，攻击者可以冒充我们的应用
- Google/Microsoft 可能会吊销我们的 OAuth2 应用

### OAuth2 Token 生命周期

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        OAuth2 Token Lifecycle                                │
│                                                                             │
│  User Login                                                                 │
│      │                                                                      │
│      ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Authorization Code Flow                                              │   │
│  │                                                                      │   │
│  │  1. User clicks "Sign in with Google"                               │   │
│  │  2. Redirect to Google login page                                   │   │
│  │  3. User grants permission                                          │   │
│  │  4. Google returns authorization_code                               │   │
│  │  5. Exchange code for tokens (requires client_secret)               │   │
│  │     POST https://oauth2.googleapis.com/token                        │   │
│  │     { client_id, client_secret, code, redirect_uri }                │   │
│  │  6. Receive: access_token (1h) + refresh_token (6mo)                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│      │                                                                      │
│      ▼                                                                      │
│  [access_token expires after 1 hour]                                       │
│      │                                                                      │
│      ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Token Refresh (requires client_secret)                              │   │
│  │                                                                      │   │
│  │  POST https://oauth2.googleapis.com/token                           │   │
│  │  { client_id, client_secret, refresh_token, grant_type=refresh }    │   │
│  │                                                                      │   │
│  │  Response: new access_token (valid for another 1h)                  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  This is why Backend must handle OAuth2:                                   │
│  client_secret is required for EVERY token refresh                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### PKCE: 无 client_secret 的替代方案

PKCE (Proof Key for Code Exchange, 发音 "pixy") 是为移动端和 SPA 设计的 OAuth2 扩展，**不需要 client_secret**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PKCE Flow                                          │
│                                                                             │
│  [On Client - generates random verifier]                                    │
│                                                                             │
│  code_verifier = random_string(43-128 chars)                               │
│  code_challenge = BASE64URL(SHA256(code_verifier))                         │
│                                                                             │
│  [Authorization Request]                                                    │
│                                                                             │
│  GET https://accounts.google.com/o/oauth2/v2/auth?                         │
│      client_id=xxx                                                          │
│      redirect_uri=myapp://callback                                          │
│      response_type=code                                                     │
│      code_challenge=abc123...      <-- NEW                                  │
│      code_challenge_method=S256    <-- NEW                                  │
│                                                                             │
│  [Token Exchange - NO client_secret needed]                                 │
│                                                                             │
│  POST https://oauth2.googleapis.com/token                                   │
│  {                                                                          │
│      client_id: "xxx",                                                      │
│      code: "authorization_code",                                            │
│      code_verifier: "original_random_string",   <-- Proves possession       │
│      redirect_uri: "myapp://callback",                                      │
│      grant_type: "authorization_code"                                       │
│  }                                                                          │
│                                                                             │
│  [Security: Only the client that generated code_verifier can exchange]     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**PKCE 安全原理**:

1. `code_verifier` 是随机生成的，每次授权不同
2. 授权请求只发送 `code_challenge` (SHA256 哈希)
3. Token 交换时需要提供原始 `code_verifier`
4. 即使攻击者拦截了 `authorization_code`，没有 `code_verifier` 也无法换取 token

### 为什么不使用 PKCE (Pad 直连)

| 因素 | Backend 代理 | PKCE (Pad 直连) |
| ---- | ------------ | --------------- |
| **Token 存储** | Backend 统一管理，Pad 只需 API 调用 | Pad 本地存储 refresh_token |
| **Token 刷新** | Backend 自动刷新，透明处理 | Pad 需要实现刷新逻辑 |
| **多设备支持** | H5 和其他 Pad 通过 Backend 访问 | 每个设备需要独立授权 |
| **用户体验** | 一次授权，所有设备可用 | 每个设备都要授权一次 |
| **开发成本** | Backend 已有实现 (Cloudflare Workers) | 需要 Pad 端完整 OAuth2 实现 |
| **离线能力** | 无 (需要 Backend 在线) | 有 (本地 token 有效期内) |

### 决策: Backend 代理 + Token 下发

综合考虑后，我们选择：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Final Decision: Hybrid Approach                           │
│                                                                             │
│  [OAuth2 Sources: Google/Outlook]                                           │
│                                                                             │
│  1. User authorizes via Mobile App                                          │
│     Mobile App ──OAuth2──▶ Google/Outlook ──tokens──▶ Backend               │
│                                                                             │
│  2. Backend stores and auto-refreshes tokens                                │
│     Backend ──refresh_token + client_secret──▶ Google ──new access_token    │
│                                                                             │
│  3. Backend syncs events to PostgreSQL                                      │
│     Cloudflare Workers ──access_token──▶ Google API ──events──▶ PostgreSQL  │
│                                                                             │
│  4. Pad fetches from Backend                                                │
│     Pad ──GET /events──▶ Backend ──events──▶ Room DB                        │
│                                                                             │
│  [Why not pass access_token to Pad for direct sync?]                        │
│                                                                             │
│  - access_token 有效期仅 1 小时                                              │
│  - 频繁通过 Heartbeat 下发 token 增加复杂度                                   │
│  - Pad 离线时无法刷新 token                                                  │
│  - Backend 代理已经工作良好，没有必要改变                                     │
│                                                                             │
│  [Basic Auth Sources: iCloud]                                               │
│                                                                             │
│  - App-Specific Password 永不过期                                            │
│  - 可以安全存储在 Pad                                                        │
│  - Pad 直连可以减轻 Backend 负担                                             │
│  - 所以 iCloud 选择 Pad 直连模式                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 未来可能的优化 (PKCE 方案)

如果未来用户规模增大，Backend 压力过大，可以考虑：

1. **Pad 端实现 PKCE 认证流程**
2. **Backend 只下发 refresh_token** (首次授权后)
3. **Pad 自行管理 token 刷新** (不需要 client_secret)
4. **Pad 直连 Google/Outlook API**

但目前这个优化的收益不明显，复杂度较高，暂不实施。

---

## 混合架构最终形态

| 数据源       | 同步模式           | 原因                                       |
| ------------ | ------------------ | ------------------------------------------ |
| **ICS**      | Pad 直连           | 简单，无认证，只读                         |
| **iCloud**   | Pad 直连           | Basic Auth 简单，App Password 永不过期     |
| **Google**   | Backend 代理       | OAuth2 需要 client_secret 刷新 token       |
| **Outlook**  | Backend 代理       | 同上                                       |
| **本地事件** | Pad 创建 → Backend | 需要多端同步                               |

```
                    ┌─────────────────────────────────────┐
                    │         Data Source Categories      │
                    ├─────────────────┬───────────────────┤
                    │   Pad Direct    │   Backend Proxy   │
                    │  (sync_mode=    │  (sync_mode=      │
                    │   pad_direct)   │   backend)        │
                    ├─────────────────┼───────────────────┤
                    │  - ICS          │  - Google         │
                    │  - iCloud       │  - Outlook        │
                    └────────┬────────┴─────────┬─────────┘
                             │                  │
                             ▼                  ▼
                    ┌─────────────────────────────────────┐
                    │        Backend (Source of Truth)    │
                    │             PostgreSQL              │
                    └─────────────────────────────────────┘
                             │                  │
                             ▼                  ▼
                    ┌─────────────────┐ ┌─────────────────┐
                    │   Pad (Room)    │ │   H5 (no cache) │
                    │  offline ready  │ │   realtime API  │
                    └─────────────────┘ └─────────────────┘
```

---

## 收益总结

| 维度         | 改进                                                |
| ------------ | --------------------------------------------------- |
| **后端压力** | ICS/iCloud 不再需要 Celery 轮询，减少 ~50% 同步任务 |
| **离线能力** | Pad 可离线查看日历                                  |
| **同步延迟** | Pad 可更频繁轮询 (用户控制)                         |
| **架构统一** | 与 Meal 模块架构一致                                |
| **H5 兼容**  | H5 无需改动，仍从 Backend 获取数据                  |

---

## 风险与缓解

| 风险                 | 缓解措施                                     |
| -------------------- | -------------------------------------------- |
| Pad 端代码复杂度增加 | 分阶段迁移，充分测试                         |
| 多端数据不一致       | Backend 作为 Source of Truth，beat flag 通知 |
| 凭证安全             | 加密存储，Heartbeat 传输使用 HTTPS           |
| 回滚困难             | 保留 sync_mode 开关，可随时切回 backend 模式 |
