# iCloud Calendar 双向同步实现计划

## 概述

为 Pronext 添加 iCloud Calendar 双向同步功能。与 Outlook/Google 不同，Apple **不提供 REST API 或 OAuth2**，而是使用 **CalDAV 协议** + **App-Specific Password** 进行认证。

### 关键差异对比

| 特性 | Google Calendar | Outlook Calendar | iCloud Calendar |
| ---- | --------------- | ---------------- | --------------- |
| 协议 | REST API (JSON) | REST API (JSON) | CalDAV (XML/ICS) |
| 认证 | OAuth2 | OAuth2 | Basic Auth + App-Specific Password |
| Token 刷新 | 自动 (refresh_token) | 自动 (refresh_token) | 无需 (密码不过期) |
| 增量同步 | Sync Token | Delta Query | 无官方支持 (需自行实现) |
| Webhook | 支持 | 支持 | 不支持 |
| 数据格式 | JSON | JSON | ICS (iCalendar) |

## 架构设计

```
┌─────────────────┐                 ┌──────────────────────────────────────┐
│  User A Device  │──credential──┐  │          Django Backend              │
├─────────────────┤              │  │  ┌────────────────────────────────┐  │
│  User B Device  │──credential──┼─▶│  │  Store icloud_credential/user   │  │
├─────────────────┤              │  │  │  (Apple ID + App Password)      │  │
│  User C Device  │──credential──┘  │  │  Polling sync (no Delta Query)  │  │
└─────────────────┘                 │  └───────────────┬────────────────┘  │
                                    └──────────────────┼───────────────────┘
                                                       │ CalDAV (on behalf of user)
                                                       ▼
                                    ┌──────────────────────────────────────┐
                                    │        iCloud CalDAV Server          │
                                    │   https://caldav.icloud.com/         │
                                    │   (Using user's Basic Auth creds)    │
                                    └──────────────────────────────────────┘
```

---

> **架构演进讨论**: 关于"后端代理 vs Pad 端直连"的完整讨论，请参阅 [CALENDAR_ARCHITECTURE_EVOLUTION.md](CALENDAR_ARCHITECTURE_EVOLUTION.md)。
> 本文档专注于 iCloud CalDAV 的技术实现细节。

---

## 后端代理架构 (当前实现)

### 同步方案

由于 iCloud CalDAV 不支持 Webhook 或 Delta Query，推荐采用 **定时轮询 + ETag 检测** 方案：

| 方案 | 优点 | 缺点 | 适用场景 |
| ---- | ---- | ---- | -------- |
| **ETag 轮询** | 实现简单，带宽开销小 | 有延迟 (5-15分钟) | 推荐 |
| **全量同步** | 最简单 | 带宽大，效率低 | 小规模用户 |

**推荐方案**: ETag 轮询

- 使用 CalDAV `PROPFIND` 获取每个事件的 ETag
- 只下载 ETag 变化的事件
- Celery Beat 每 5-10 分钟批量检查

---

## 前置条件：用户生成 App-Specific Password

> **重要**: iCloud 不支持 OAuth2，用户必须手动生成 App-Specific Password 并提供给应用。

### 用户操作步骤

#### 前提条件
- 用户的 Apple Account 必须启用双重认证 (Two-Factor Authentication)
- 需要 iPhone/iPad/Mac 设备来启用双重认证

#### 方法 1: 通过 account.apple.com (推荐)

1. 访问 [https://account.apple.com](https://account.apple.com)
2. 使用 Apple ID 登录
3. 在 **Sign-In and Security** (登录与安全) 部分，点击 **App-Specific Passwords** (App 专用密码)
4. 点击 **Generate an app-specific password** (生成 App 专用密码) 或点击 **+** 按钮
5. 输入密码标签 (如 "Pronext Calendar")
6. 点击 **Create** (创建)
7. **复制生成的 16 位密码** (格式: xxxx-xxxx-xxxx-xxxx)

#### 方法 2: 通过 iCloud.com

1. 访问 [https://www.icloud.com](https://www.icloud.com)
2. 登录后点击 **Manage Apple ID** (管理 Apple ID)
3. 点击 **App-Specific Passwords** (App 专用密码)
4. 输入密码标签并点击 **Create** (创建)
5. 复制生成的密码

### 在 Pronext 中配置

用户需要在 Pronext App 中提供：
- **Apple ID**: 通常是邮箱地址 (如 `user@icloud.com`)
- **App-Specific Password**: 16 位密码 (格式: xxxx-xxxx-xxxx-xxxx)

**官方参考**: [Sign in to apps with your Apple Account using app-specific passwords](https://support.apple.com/en-us/102654)

---

## 技术实现详情

### CalDAV 服务器地址

| 用途 | URL |
| ---- | --- |
| 基础服务器 | `https://caldav.icloud.com/` |
| Principal URL | `https://pXX-caldav.icloud.com/{USER_ID}/principal/` |
| Calendar Home | `https://pXX-caldav.icloud.com/{USER_ID}/calendars/` |
| 单个日历 | `https://pXX-caldav.icloud.com/{USER_ID}/calendars/{CALENDAR_ID}/` |

> 注意: `pXX` 是服务器分片编号 (如 p34, p12)，`USER_ID` 是用户唯一标识，这些值通过 CalDAV 发现机制获取。

### CalDAV 发现流程

```
1. PROPFIND https://caldav.icloud.com/
   ├─ 请求: current-user-principal
   └─ 响应: /200385701/principal/

2. PROPFIND https://pXX-caldav.icloud.com/200385701/principal/
   ├─ 请求: calendar-home-set
   └─ 响应: https://p34-caldav.icloud.com:443/200385701/calendars/

3. PROPFIND https://p34-caldav.icloud.com/200385701/calendars/
   ├─ 请求: displayname, supported-calendar-component-set
   └─ 响应: 日历列表
```

### HTTP 认证头

```
Authorization: Basic base64(apple_id:app_specific_password)
```

示例:
```python
import base64
credentials = base64.b64encode(f"{apple_id}:{app_password}".encode()).decode()
headers = {"Authorization": f"Basic {credentials}"}
```

### iCloud CalDAV 限制

- **不支持 FreeBusy 请求**
- **不支持任务/提醒事项 (Tasks/Journals)** - 仅支持基本事件
- **无 Delta Query** - 需要自行实现增量同步
- **无 Webhook** - 只能轮询检测变更

---

## Python 推荐库

### 主要库: caldav (推荐)

Python CalDAV 客户端库，活跃维护中。

```bash
pip install caldav>=2.2.3
```

| 版本 | 发布日期 | 维护周期 |
| ---- | -------- | -------- |
| 2.2.x | 2025-12 | 至 2027+ |
| 1.x | 已过时 | 至 2026-01 |

**文档**: [caldav.readthedocs.io](https://caldav.readthedocs.io/stable/about.html)

**GitHub**: [python-caldav/caldav](https://github.com/python-caldav/caldav)

#### 基本使用示例

```python
import caldav
from caldav.elements import dav

# 连接到 iCloud
client = caldav.DAVClient(
    url="https://caldav.icloud.com/",
    username="user@icloud.com",
    password="xxxx-xxxx-xxxx-xxxx"  # App-Specific Password
)

# 获取 principal
principal = client.principal()

# 获取所有日历
calendars = principal.calendars()
for cal in calendars:
    print(f"Calendar: {cal.name}, URL: {cal.url}")

# 获取事件
calendar = calendars[0]
events = calendar.date_search(
    start=datetime(2025, 1, 1),
    end=datetime(2025, 12, 31)
)

for event in events:
    print(event.data)  # ICS 格式数据
```

### 辅助库

| 库 | 用途 | 安装 |
| -- | ---- | ---- |
| `icalendar` | 解析/生成 ICS 文件 | `pip install icalendar` |
| `python-dateutil` | 处理 RRULE | `pip install python-dateutil` |
| `recurring-ical-events` | 展开重复事件 | `pip install recurring-ical-events` |

### 参考项目

**icloud-calendar-manager**: 完整的 iCloud CalDAV 示例代码

- GitHub: [thinkingserious/icloud-calendar-manager](https://github.com/thinkingserious/icloud-calendar-manager)
- 功能: list, retrieve, add, update, delete events

---

## TypeScript/JavaScript 推荐库 (供 Pad/Flutter 参考)

### 主要库: tsdav

WebDAV/CalDAV/CardDAV 客户端，支持 Browser 和 Node.js。

```bash
npm install tsdav
# 或
yarn add tsdav
```

**GitHub**: [natelindev/tsdav](https://github.com/natelindev/tsdav)

**npm**: [tsdav](https://www.npmjs.com/package/tsdav)

#### 使用示例

```typescript
import { createDAVClient } from 'tsdav';

const client = await createDAVClient({
  serverUrl: 'https://caldav.icloud.com/',
  credentials: {
    username: 'user@icloud.com',
    password: 'xxxx-xxxx-xxxx-xxxx',
  },
  authMethod: 'Basic',
  defaultAccountType: 'caldav',
});

const calendars = await client.fetchCalendars();
const events = await client.fetchCalendarObjects({
  calendar: calendars[0],
});
```

### 辅助库

| 库 | 用途 | 安装 |
| -- | ---- | ---- |
| `ical.js` | 解析 ICS | `npm install ical.js` |
| `ical-generator` | 生成 ICS | `npm install ical-generator` |

### 替代库: ts-caldav

更轻量的 CalDAV 客户端，支持 React Native。

**GitHub**: [KlautNet/ts-caldav](https://github.com/KlautNet/ts-caldav)

---

## 实现阶段

### Phase 1: 核心认证和只读同步

**目标**: 实现 iCloud CalDAV 连接，从 iCloud 拉取事件到本地

#### 1.1 数据模型变更

**文件**: `server/pronext/calendar/models.py`

在 `SyncedCalendar` 模型添加字段:

```python
# iCloud 凭证 (存储 Apple ID 和 App-Specific Password)
icloud_credential = models.JSONField(null=True, blank=True)
# 格式: {"apple_id": "user@icloud.com", "app_password": "xxxx-xxxx-xxxx-xxxx"}

icloud_principal_url = models.URLField(max_length=500, blank=True)
icloud_calendar_url = models.URLField(max_length=500, blank=True)

# 用于增量同步的 ctag/etag
icloud_ctag = models.CharField(max_length=200, blank=True)
icloud_last_sync = models.DateTimeField(null=True, blank=True)
```

#### 1.2 创建 ICloudCalendar 类

**新文件**: `server/pronext/calendar/sync_icloud.py`

```python
import caldav
from caldav.elements import dav
from icalendar import Calendar, Event as ICalEvent

class ICloudCalendar:
    CALDAV_URL = "https://caldav.icloud.com/"

    def __init__(self, credential: dict, calendar_url: str = None):
        self.apple_id = credential.get("apple_id")
        self.app_password = credential.get("app_password")
        self.calendar_url = calendar_url
        self._client = None
        self._calendar = None

    @property
    def client(self) -> caldav.DAVClient:
        if not self._client:
            self._client = caldav.DAVClient(
                url=self.CALDAV_URL,
                username=self.apple_id,
                password=self.app_password
            )
        return self._client

    def get_calendars(self) -> list[dict]:
        """获取用户的所有日历"""
        principal = self.client.principal()
        calendars = principal.calendars()
        return [
            {
                "url": str(cal.url),
                "name": cal.name,
                "color": cal.get_properties([dav.Href()]).get("calendar-color", "#0078D4"),
            }
            for cal in calendars
        ]

    def get_events(self, start_date, end_date) -> list[dict]:
        """获取指定时间范围内的事件"""
        calendar = caldav.Calendar(client=self.client, url=self.calendar_url)
        events = calendar.date_search(start=start_date, end=end_date)

        result = []
        for event in events:
            cal = Calendar.from_ical(event.data)
            for component in cal.walk():
                if component.name == "VEVENT":
                    result.append(self._parse_vevent(component, event.url))
        return result

    def _parse_vevent(self, vevent, url) -> dict:
        """解析 VEVENT 到内部格式"""
        return {
            "uid": str(vevent.get("UID", "")),
            "url": str(url),
            "title": str(vevent.get("SUMMARY", "")),
            "description": str(vevent.get("DESCRIPTION", "")),
            "start": vevent.get("DTSTART").dt if vevent.get("DTSTART") else None,
            "end": vevent.get("DTEND").dt if vevent.get("DTEND") else None,
            "rrule": str(vevent.get("RRULE", "")),
            "location": str(vevent.get("LOCATION", "")),
        }

    def add_event(self, event_data: dict) -> str:
        """创建新事件，返回 UID"""
        # ... ICS 生成和上传
        pass

    def update_event(self, event_url: str, event_data: dict) -> bool:
        """更新已有事件"""
        # ... ICS 更新
        pass

    def delete_event(self, event_url: str) -> bool:
        """删除事件"""
        calendar = caldav.Calendar(client=self.client, url=self.calendar_url)
        event = calendar.event_by_url(event_url)
        event.delete()
        return True
```

#### 1.3 API 端点

**文件**: `server/pronext/calendar/viewset_app.py`

新增 actions:

```python
@action(detail=False, methods=["POST"])
def icloud(self, request, device_id=None):
    """添加 iCloud 日历"""
    serializer = ICloudSyncedCalendarSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    # 验证凭证并创建 SyncedCalendar
    ...

@action(detail=False, methods=["POST"])
def verify_icloud_credential(self, request, device_id=None):
    """验证 iCloud 凭证并返回日历列表"""
    apple_id = request.data.get("apple_id")
    app_password = request.data.get("app_password")

    ic = ICloudCalendar({"apple_id": apple_id, "app_password": app_password})
    try:
        calendars = ic.get_calendars()
        return Response({"calendars": calendars})
    except Exception as e:
        return Response({"error": str(e)}, status=400)
```

#### 1.4 同步逻辑

**文件**: `server/pronext/calendar/options.py`

```python
def _get_icloud(synced: SyncedCalendar) -> ICloudCalendar:
    """获取 ICloudCalendar 实例"""
    return ICloudCalendar(
        credential=synced.icloud_credential,
        calendar_url=synced.icloud_calendar_url
    )

# 修改 sync_calendar() 支持 iCloud 类型
```

---

### Phase 2: 双向同步

**目标**: 本地事件变更推送到 iCloud

#### 2.1 ICS 生成

**文件**: `server/pronext/calendar/sync_icloud.py`

```python
from icalendar import Calendar, Event as ICalEvent, vText
from datetime import datetime
import uuid

def create_ics_event(event_data: dict) -> str:
    """从内部数据生成 ICS 格式"""
    cal = Calendar()
    cal.add("prodid", "-//Pronext//Calendar//EN")
    cal.add("version", "2.0")

    event = ICalEvent()
    event.add("uid", event_data.get("uid") or str(uuid.uuid4()))
    event.add("summary", event_data["title"])
    event.add("dtstart", event_data["start"])
    event.add("dtend", event_data["end"])

    if event_data.get("description"):
        event.add("description", event_data["description"])
    if event_data.get("location"):
        event.add("location", event_data["location"])
    if event_data.get("rrule"):
        # RRULE 处理
        pass

    event.add("dtstamp", datetime.utcnow())
    cal.add_component(event)

    return cal.to_ical().decode("utf-8")
```

#### 2.2 RRULE 转换

iCloud 使用标准 iCalendar RRULE 格式，与 Pronext 内部格式兼容性较好。

```python
def _convert_rrule_to_ical(rrule_str: str) -> str:
    """Pronext RRULE -> iCalendar RRULE"""
    # 通常是直接兼容的
    return rrule_str

def _convert_ical_to_rrule(vevent) -> str:
    """iCalendar RRULE -> Pronext RRULE"""
    rrule = vevent.get("RRULE")
    if rrule:
        return rrule.to_ical().decode("utf-8")
    return ""
```

#### 2.3 事件 CRUD 集成

**文件**: `server/pronext/calendar/options.py`

修改函数支持 iCloud:

- `add_event()` - 创建事件时同步到 iCloud
- `update_event()` - 更新事件时同步到 iCloud
- `delete_event()` - 删除事件时同步到 iCloud

---

### Phase 3: ETag 增量同步

**目标**: 高效检测和同步变更

#### 3.1 CTag/ETag 机制

CalDAV 支持两种变更检测：

- **CTag (Calendar Tag)**: 日历级别，任何事件变更都会改变
- **ETag (Entity Tag)**: 事件级别，单个事件的版本标识

```python
def check_calendar_changed(self) -> bool:
    """检查日历是否有变更 (通过 CTag)"""
    calendar = caldav.Calendar(client=self.client, url=self.calendar_url)
    props = calendar.get_properties([dav.GetCtag()])
    current_ctag = props.get("{http://calendarserver.org/ns/}getctag")
    return current_ctag != self.cached_ctag

def get_changed_events(self) -> list:
    """获取变更的事件 (通过 ETag 对比)"""
    calendar = caldav.Calendar(client=self.client, url=self.calendar_url)

    # 获取所有事件的 ETag
    events_with_etag = calendar.events()

    changed = []
    for event in events_with_etag:
        etag = event.get_properties([dav.GetEtag()]).get("{DAV:}getetag")
        cached_etag = self.get_cached_etag(event.url)
        if etag != cached_etag:
            changed.append(event)

    return changed
```

#### 3.2 数据模型扩展

**文件**: `server/pronext/calendar/models.py`

```python
# SyncedCalendar 新增字段
icloud_ctag = models.CharField(max_length=200, blank=True)
icloud_etag_cache = models.JSONField(default=dict, blank=True)
# 格式: {"event_url": "etag_value", ...}

icloud_last_sync = models.DateTimeField(null=True, blank=True)
icloud_sync_priority = models.IntegerField(default=0)
```

#### 3.3 Celery 批量同步任务

**文件**: `server/pronext/calendar/tasks.py`

```python
@celery_app.task
def batch_sync_icloud_calendars():
    """
    每 5-10 分钟运行，批量同步 iCloud 日历
    """
    calendars = SyncedCalendar.objects.filter(
        calendar_type=SyncedCalendar.Type.ICLOUD,
        is_active=True,
        icloud_credential__isnull=False,
    ).order_by('-icloud_sync_priority', 'icloud_last_sync')[:100]

    for synced in calendars:
        sync_single_icloud_calendar.delay(synced.id)

@celery_app.task
def sync_single_icloud_calendar(synced_calendar_id):
    """同步单个 iCloud 日历"""
    synced = SyncedCalendar.objects.get(id=synced_calendar_id)
    ic = ICloudCalendar(synced.icloud_credential, synced.icloud_calendar_url)

    # 检查 CTag 是否变化
    if not ic.check_calendar_changed(synced.icloud_ctag):
        synced.icloud_last_sync = timezone.now()
        synced.save(update_fields=['icloud_last_sync'])
        return

    # 获取变更的事件
    changed_events = ic.get_changed_events(synced.icloud_etag_cache)

    for event in changed_events:
        # 处理变更...
        pass

    # 更新缓存
    synced.icloud_ctag = ic.get_current_ctag()
    synced.icloud_last_sync = timezone.now()
    synced.save()
```

#### 3.4 Celery Beat 配置

```python
CELERY_BEAT_SCHEDULE = {
    'batch-sync-icloud': {
        'task': 'pronext.calendar.tasks.batch_sync_icloud_calendars',
        'schedule': crontab(minute='*/10'),  # 每 10 分钟
    },
}
```

---

### Phase 4: 冲突解决和测试

#### 4.1 冲突解决策略

基于 `LAST-MODIFIED` 时间戳的最后写入胜出:

```python
def resolve_conflict(local_event, remote_event) -> str:
    local_modified = local_event.updated_at
    remote_modified = remote_event.get("LAST-MODIFIED")
    return 'local' if local_modified > remote_modified else 'remote'
```

#### 4.2 测试

**新文件**: `server/pronext/calendar/tests/test_icloud_sync.py`

- CalDAV 连接测试 (mock)
- ICS 解析/生成测试
- RRULE 转换测试
- ETag 增量同步测试
- 冲突解决测试

---

## 关键文件清单

| 操作 | 文件路径 |
| ---- | ------- |
| 新建 | `server/pronext/calendar/sync_icloud.py` |
| 新建 | `server/pronext/calendar/migrations/00XX_add_icloud_fields.py` |
| 新建 | `server/pronext/calendar/tests/test_icloud_sync.py` |
| 修改 | `server/pronext/calendar/models.py` |
| 修改 | `server/pronext/calendar/options.py` |
| 修改 | `server/pronext/calendar/viewset_app.py` |
| 修改 | `server/pronext/calendar/viewset_serializers.py` |
| 修改 | `server/pronext/calendar/sync_event.py` |
| 修改 | `server/pronext/calendar/tasks.py` |
| 修改 | `server/requirements.txt` |

---

## 依赖

**后端 (Python)**:

```
caldav>=2.2.3          # CalDAV 客户端
icalendar>=5.0.0       # ICS 解析/生成
recurring-ical-events>=2.0.0  # 重复事件展开
```

**前端参考 (TypeScript/JavaScript)**:

```
tsdav>=2.1.0           # CalDAV 客户端
ical.js>=1.5.0         # ICS 解析
ical-generator>=6.0.0  # ICS 生成
```

---

## 安全考虑

### 凭证存储

由于 iCloud 使用 App-Specific Password 而非 OAuth2：

1. **加密存储**: `icloud_credential` 字段应该加密存储
2. **传输安全**: 所有 API 使用 HTTPS
3. **权限隔离**: 每个用户只能访问自己的凭证
4. **密码不过期**: App-Specific Password 永久有效，除非用户主动撤销

### 建议

```python
# 使用 Django 加密字段
from django_cryptography.fields import encrypt

class SyncedCalendar(models.Model):
    icloud_credential = encrypt(models.JSONField(null=True, blank=True))
```

或使用环境变量中的密钥进行 AES 加密存储。

---

## 用户体验流程

### 添加 iCloud 日历

```
1. 用户点击 "添加 iCloud 日历"
2. 显示说明页面，引导用户生成 App-Specific Password
3. 用户输入 Apple ID 和 App-Specific Password
4. 后端验证凭证，返回日历列表
5. 用户选择要同步的日历
6. 创建 SyncedCalendar 记录，开始同步
```

### 前端 UI 考虑

- 提供详细的 App-Specific Password 生成指引 (可链接到 Apple 官方文档)
- 密码输入框显示格式提示 (xxxx-xxxx-xxxx-xxxx)
- 验证失败时显示友好的错误信息

---

## 风险和挑战

| 风险 | 影响 | 缓解措施 |
| ---- | ---- | ------- |
| 无 OAuth2 | 高 | 详细的用户引导，加密存储凭证 |
| 无 Delta Query | 中 | 使用 CTag/ETag 机制优化 |
| 无 Webhook | 中 | 定时轮询，按优先级分批处理 |
| iCloud 服务器分片 | 低 | caldav 库自动处理发现流程 |
| 文档不完善 | 中 | 参考开源项目，充分测试 |
| 账户安全敏感 | 高 | App-Specific Password 可随时撤销 |

---

## 参考资源

### 官方文档
- [Apple App-Specific Passwords](https://support.apple.com/en-us/102654)
- [CalDAV (RFC 4791)](https://datatracker.ietf.org/doc/html/rfc4791)
- [iCalendar (RFC 5545)](https://datatracker.ietf.org/doc/html/rfc5545)

### 库文档
- [Python caldav](https://caldav.readthedocs.io/stable/about.html)
- [tsdav](https://github.com/natelindev/tsdav)

### 参考项目
- [icloud-calendar-manager](https://github.com/thinkingserious/icloud-calendar-manager)
- [OneCal iCloud Integration Guide](https://www.onecal.io/blog/how-to-integrate-icloud-calendar-api-into-your-app)
- [Aurinko CalDAV Guide](https://www.aurinko.io/blog/caldav-apple-calendar-integration/)

---

## 下一步行动

本文档为计划文档，下次会话实施时按以下顺序进行：

1. **Phase 1** - 核心认证和只读同步
   - 安装依赖 (`caldav`, `icalendar`)
   - 创建 `sync_icloud.py`
   - 添加数据模型字段
   - 实现 API 端点
   - 基础同步功能

2. **Phase 2** - 双向同步
   - ICS 生成
   - CRUD 集成

3. **Phase 3** - ETag 增量同步
   - 变更检测
   - Celery 任务

4. **Phase 4** - 测试和优化
   - 单元测试
   - 集成测试
   - 错误处理完善

> **架构演进**: 关于 Pad 端直连的长期架构规划，请参阅 [CALENDAR_ARCHITECTURE_EVOLUTION.md](CALENDAR_ARCHITECTURE_EVOLUTION.md)
