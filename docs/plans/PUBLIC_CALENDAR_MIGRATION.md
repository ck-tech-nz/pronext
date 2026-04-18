# 公共日历转换方案

## 背景

分析生产数据发现，多个用户订阅了相同的日历链接（如节假日日历），导致：

- **35个重复的 link** 在 SyncedCalendar 表中
- **数据重复存储**：同一日历的事件被复制多份（如 US Holidays 的134个事件被存储了3份）
- **同步资源浪费**：相同日历被多次同步

### 数据统计

| 类型 | 示例 | 用户数 | 事件数/份 | 性质 |
| ---- | ---- | ------ | --------- | ---- |
| 节假日日历 | US Holidays (icloud) | 3 | 134 | 公共 |
| 节假日日历 | US Federal Holidays | 2 | 23 | 公共 |
| 家庭日历 | Family (iCloud共享) | 3 | 470 | 私有（本次不处理）|

### 现有基础设施

- `SyncedCalendar.is_public` - 标记公共日历
- `SyncedCalendar.is_active` - 标记日历是否激活（已存在）
- `CalendarSubscription` 模型（已有185条记录在使用）
- `SubscriptionService` 服务类

---

## 需要迁移的公共日历

| 名称 | Link | 用户数 | 用户IDs | 日历IDs | 事件数 |
| ---- | ---- | ------ | ------- | ------- | ------ |
| US Holidays | `calendars.icloud.com/holidays/us_en-us.ics` | 3 | 907, 4795, 776 | 1719, 4941, 3462 | 134 |
| US Holidays | `p24-calendars.icloud.com/holiday/US_en.ics` | 2 | 1190, 4440 | 1855, 4559 | 134 |
| US Federal Holidays | `officeholidays.com/ics-fed/usa` | 2 | 504, 3029 | 1682, 3419 | 23 |

**注意**: 其中日历 ID 3462 已标记为 `is_public=True`，是目前唯一的公共日历。

---

## 实施方案

### 第一步：更新 API 过滤 is_active=False 的日历

**文件**: `pronext/calendar/viewset_app.py`

修改 `SyncedCalendarViewSet._list()` 方法：

```python
# 修改前
qs = SyncedCalendar.objects.filter(user_id=device_id).select_related("user").order_by('-id')

# 修改后
qs = SyncedCalendar.objects.filter(user_id=device_id, is_active=True).select_related("user").order_by('-id')
```

同样修改 `_detail()` 方法。

### 第二步：创建迁移命令

**新建文件**: `pronext/calendar/management/commands/migrate_public_calendars.py`

迁移公共日历的步骤：

1. 创建一个新的公共日历 (is_public=True, is_active=True)
2. 同步该日历获取事件
3. 为每个原订阅用户创建 CalendarSubscription
4. 将旧的重复日历设为 is_active=False
5. 删除旧日历的重复事件

迁移命令功能：

- `--dry-run`: 仅显示将要执行的操作
- `--rollback`: 回滚迁移（重新激活旧日历）

---

## 迁移流程详解

```text
┌─────────────────────────────────────────────────────────────────┐
│  迁移前状态                                                      │
├─────────────────────────────────────────────────────────────────┤
│  SyncedCalendar (ID: 1719)                                      │
│    user: 907, link: calendars.icloud.com/holidays/us_en-us.ics  │
│    is_active: True, is_public: False                            │
│    Events: 134                                                   │
├─────────────────────────────────────────────────────────────────┤
│  SyncedCalendar (ID: 3462)                                      │
│    user: 776, link: calendars.icloud.com/holidays/us_en-us.ics  │
│    is_active: True, is_public: True  ← 现有唯一的 public        │
│    Events: 134                                                   │
├─────────────────────────────────────────────────────────────────┤
│  SyncedCalendar (ID: 4941)                                      │
│    user: 4795, link: calendars.icloud.com/holidays/us_en-us.ics │
│    is_active: True, is_public: False                            │
│    Events: 134                                                   │
└─────────────────────────────────────────────────────────────────┘

                              ↓ 迁移

┌─────────────────────────────────────────────────────────────────┐
│  迁移后状态                                                      │
├─────────────────────────────────────────────────────────────────┤
│  SyncedCalendar (ID: NEW)  ← 新创建的公共日历                    │
│    user: admin, link: calendars.icloud.com/holidays/us_en-us.ics│
│    is_active: True, is_public: True                             │
│    Events: 134                                                   │
├─────────────────────────────────────────────────────────────────┤
│  SyncedCalendar (ID: 1719, 3462, 4941)  ← 旧日历全部禁用        │
│    is_active: False                                              │
│    Events: 已删除                                                │
├─────────────────────────────────────────────────────────────────┤
│  CalendarSubscription (NEW)                                      │
│    user: 907, synced_calendar: NEW                              │
│  CalendarSubscription (NEW)                                      │
│    user: 776, synced_calendar: NEW                              │
│  CalendarSubscription (NEW)                                      │
│    user: 4795, synced_calendar: NEW                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## 验证计划

### 迁移前

```bash
cd server
source .venv/bin/activate
python manage.py migrate_public_calendars --dry-run
```

### 迁移后

1. **API 验证**：

   ```bash
   # 检查 synced/list 不返回 is_active=False 的日历
   curl "/calendar/device/{device_id}/synced/list"

   # 检查 subscription/available 返回新的公共日历
   curl "/calendar/device/{device_id}/subscription/available"
   ```

2. **数据验证**：

   ```python
   # 旧日历已禁用
   SyncedCalendar.objects.filter(link__contains='holidays', is_active=False).count()

   # 新公共日历存在
   SyncedCalendar.objects.filter(is_public=True, is_active=True)

   # 订阅已创建
   CalendarSubscription.objects.filter(synced_calendar__is_public=True)
   ```

3. **端到端测试**：
   - 登录原用户账号
   - 确认能在订阅列表看到 US Holidays
   - 确认事件正常显示

### 回滚

```bash
python manage.py migrate_public_calendars --rollback
```

---

## 隐私说明

本次仅处理**节假日等公共日历**，不涉及用户私有数据：

- 节假日日历内容本身是公开信息
- 家庭共享日历不在本次迁移范围内
- 用户的订阅关系保持不变，只是数据源变更
