# Outlook 日历同步测试计划

> 本文档提供完整的 Outlook 日历同步功能测试步骤

## 测试环境准备

### 1. 启动 Django 后端

```bash
cd server
source .venv/bin/activate
python3 manage.py runserver 0.0.0.0:8000
```

### 2. 启动 Vue 前端 (可选，如果测试 H5)

```bash
cd vue
npm run dev
```

### 3. 启动 Flutter App

```bash
cd flutter
flutter run
```

### 4. 启动 Go Outlook Syncer (本地 Mac)

```bash
cd server/scripts/go/outlook_syncer

# 设置环境变量
export API_DOMAIN=http://localhost:8000
export SYNC_AUTH_HEADER="Iq6809YDLZo2ZOz5GKfl0qDsfSySTNIHy0W6Ryz7DnIYJY3m31ev0E9PDHJxCR0b"

# 运行
go run *.go -c 1 -i 30s
```

**参数说明**:
- `-c 1`: 并发数为 1（调试时建议设为 1）
- `-i 30s`: 同步间隔 30 秒（调试时可以设短一些）

### 5. 准备测试 Outlook 账户

确保有一个可用的 Outlook/Hotmail/Live 账户，并在 Outlook Web (outlook.live.com) 中可以管理日历。

---

## 测试前：添加 Outlook 日历

### 步骤 1: 在 App 中添加 Outlook 日历

1. 打开 Flutter App
2. 进入 Settings → Synced Calendars → Add Calendar
3. 点击 "Outlook, Hotmail or Live"
4. 选择同步方式：
   - **One-way sync** (单向：Outlook → App)
   - **Two-way sync** (双向：Outlook ↔ App)
5. 点击 "Connect with Microsoft"
6. 在弹出的浏览器中登录 Microsoft 账户并授权
7. 授权成功后返回 App，选择要同步的日历
8. 确认日历已添加成功

### 步骤 2: 验证日历已创建

在 Django Admin 中验证：
```
http://localhost:8000/admin/calendar/syncedcalendar/
```

检查：
- `calendar_type` = 2 (Outlook)
- `outlook_calendar_id` 已填充
- `google_credit` 包含 access_token 和 refresh_token
- `synced_style` = 1 (one-way) 或 2 (two-way)

---

## 一、单向同步测试 (One-way: Outlook → App)

> 选择 synced_style = 1 的日历进行测试

### 测试 1.1: 基本事件同步

#### 从 Outlook 添加普通事件

1. 打开 Outlook Web (outlook.live.com)
2. 创建一个新事件:
   - **Title**: "Test Event - Normal"
   - **Date**: 明天
   - **Time**: 10:00 - 11:00
   - **Location**: "Meeting Room A"
   - **Description**: "This is a test event"
3. 保存事件

#### 验证同步

**方式 A: 手动触发同步**
```
http://localhost:8000/sync_calendar/{synced_calendar_id}/
```

**方式 B: 等待 Go Syncer 自动同步** (查看终端日志)

**方式 C: Django Shell 手动同步**
```python
from pronext.calendar.options import sync_calendar
from pronext.calendar.models import SyncedCalendar
from pronext.device.models import UserDeviceRel

synced = SyncedCalendar.objects.get(id={synced_calendar_id})
rels = UserDeviceRel.objects.filter(device_id=synced.user_id)
rel_user_ids = [rel.user_id for rel in rels]
sync_calendar(synced, rel_user_ids)
```

#### 预期结果
- [ ] App 中显示 "Test Event - Normal"
- [ ] 事件时间正确 (10:00 - 11:00)
- [ ] Location 和 Description 正确显示

---

### 测试 1.2: 全天事件同步

1. 在 Outlook 创建全天事件:
   - **Title**: "Test Event - All Day"
   - **All day**: ✓ 勾选
   - **Date**: 后天
2. 触发同步
3. 验证 App 中显示全天事件

#### 预期结果
- [ ] 事件显示为全天事件
- [ ] 日期正确

---

### 测试 1.3: 重复事件同步 - Daily

1. 在 Outlook 创建每日重复事件:
   - **Title**: "Daily Standup"
   - **Time**: 09:00 - 09:15
   - **Repeat**: Daily
   - **End**: After 5 occurrences
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 事件在未来 5 天都显示
- [ ] 重复图标正确显示
- [ ] 每天时间正确

---

### 测试 1.4: 重复事件同步 - Weekly

1. 在 Outlook 创建每周重复事件:
   - **Title**: "Weekly Review"
   - **Time**: 14:00 - 15:00
   - **Repeat**: Weekly, every Monday and Friday
   - **End**: No end date
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 事件在周一和周五都显示
- [ ] 重复模式正确

---

### 测试 1.5: 重复事件同步 - Monthly

1. 在 Outlook 创建每月重复事件:
   - **Title**: "Monthly Report"
   - **Time**: 10:00 - 11:00
   - **Repeat**: Monthly, on the 15th
   - **End**: After 3 occurrences
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 事件在每月 15 日显示
- [ ] 共显示 3 次

---

### 测试 1.6: 重复事件同步 - Yearly

1. 在 Outlook 创建每年重复事件:
   - **Title**: "Anniversary"
   - **All day**: ✓
   - **Repeat**: Yearly, on March 15
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 事件在每年 3 月 15 日显示

---

### 测试 1.7: 修改事件

1. 在 Outlook 中修改之前创建的 "Test Event - Normal":
   - 修改 **Title** → "Test Event - Modified"
   - 修改 **Time** → 11:00 - 12:00
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 标题更新为 "Test Event - Modified"
- [ ] 时间更新为 11:00 - 12:00

---

### 测试 1.8: 修改重复事件 - This Event Only

1. 在 Outlook 中打开 "Daily Standup" 的第 3 次重复
2. 选择 "Edit this event only"
3. 修改标题为 "Daily Standup - Special"
4. 触发同步
5. 在 App 中验证

#### 预期结果
- [ ] 只有第 3 天的标题变为 "Daily Standup - Special"
- [ ] 其他天保持原标题

---

### 测试 1.9: 修改重复事件 - This and Future Events

1. 在 Outlook 中打开 "Weekly Review" 的某一天
2. 选择 "Edit this and future events"
3. 修改时间为 15:00 - 16:00
4. 触发同步
5. 在 App 中验证

#### 预期结果
- [ ] 修改日期之前的事件保持原时间
- [ ] 修改日期及之后的事件变为新时间

---

### 测试 1.10: 删除事件 - Single Event

1. 在 Outlook 中删除 "Test Event - Modified"
2. 触发同步
3. 在 App 中验证

#### 预期结果
- [ ] 事件从 App 中消失

---

### 测试 1.11: 删除重复事件 - This Event Only

1. 在 Outlook 中打开 "Daily Standup" 的第 2 次重复
2. 选择 "Delete this event only"
3. 触发同步
4. 在 App 中验证

#### 预期结果
- [ ] 只有第 2 天的事件消失
- [ ] 其他天的事件仍在

---

### 测试 1.12: 删除重复事件 - This and Future Events

1. 在 Outlook 中打开 "Weekly Review" 的某一天
2. 选择 "Delete this and future events"
3. 触发同步
4. 在 App 中验证

#### 预期结果
- [ ] 删除日期及之后的所有实例消失
- [ ] 删除日期之前的实例仍在

---

### 测试 1.13: 删除重复事件 - All Events

1. 在 Outlook 中打开 "Monthly Report"
2. 选择 "Delete all events in series"
3. 触发同步
4. 在 App 中验证

#### 预期结果
- [ ] 所有实例都从 App 中消失

---

## 二、双向同步测试 (Two-way: Outlook ↔ App)

> 选择 synced_style = 2 的日历进行测试
> 注意：需要先添加一个新的 Two-way 同步的 Outlook 日历

### 测试 2.1: 从 App 添加普通事件到 Outlook

1. 在 App 中创建新事件:
   - **Title**: "App Event - Normal"
   - **Date**: 后天
   - **Time**: 14:00 - 15:00
   - **Category**: 选择已关联 Outlook 日历的 Profile
2. 保存事件
3. 打开 Outlook Web 验证

#### 预期结果
- [ ] Outlook 中显示 "App Event - Normal"
- [ ] 时间和日期正确

---

### 测试 2.2: 从 App 添加全天事件

1. 在 App 中创建全天事件:
   - **Title**: "App Event - All Day"
   - **All day**: ✓
   - **Date**: 大后天
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中显示为全天事件

---

### 测试 2.3: 从 App 添加每日重复事件

1. 在 App 中创建重复事件:
   - **Title**: "App Daily Task"
   - **Time**: 08:00 - 08:30
   - **Repeat**: Daily
   - **End**: After 7 days
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中显示每日重复事件
- [ ] 重复 7 次

---

### 测试 2.4: 从 App 添加每周重复事件

1. 在 App 中创建:
   - **Title**: "App Weekly Meeting"
   - **Time**: 10:00 - 11:00
   - **Repeat**: Weekly, on Tuesday and Thursday
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中显示周二和周四的重复事件

---

### 测试 2.5: 从 App 添加每月重复事件

1. 在 App 中创建:
   - **Title**: "App Monthly Check"
   - **Time**: 09:00 - 10:00
   - **Repeat**: Monthly, on the 1st
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中显示每月 1 日的事件

---

### 测试 2.6: 从 App 添加每年重复事件

1. 在 App 中创建:
   - **Title**: "App Yearly Review"
   - **All day**: ✓
   - **Repeat**: Yearly
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中显示每年同一天的事件

---

### 测试 2.7: 从 App 修改事件 - 基本信息

1. 在 App 中编辑 "App Event - Normal":
   - 修改 **Title** → "App Event - Updated"
   - 修改 **Time** → 15:00 - 16:00
2. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中标题和时间已更新

---

### 测试 2.8: 从 App 修改重复事件 - This Event Only

1. 在 App 中打开 "App Daily Task" 的第 3 天
2. 选择 "Edit this event"
3. 修改标题为 "App Daily Task - Exception"
4. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中只有第 3 天的标题变化
- [ ] 其他天保持原样

---

### 测试 2.9: 从 App 修改重复事件 - This and Future Events

1. 在 App 中打开 "App Weekly Meeting" 的某一天
2. 选择 "Edit this and future events"
3. 修改时间为 11:00 - 12:00
4. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中修改日期之后的时间变为 11:00 - 12:00
- [ ] 之前的保持原时间

---

### 测试 2.10: 从 App 修改重复事件 - All Events

1. 在 App 中打开 "App Monthly Check"
2. 选择 "Edit all events"
3. 修改标题为 "App Monthly Check - Updated"
4. 保存并验证 Outlook

#### 预期结果
- [ ] Outlook 中所有实例标题都更新

---

### 测试 2.11: 从 App 删除事件 - Single Event

1. 在 App 中删除 "App Event - Updated"
2. 验证 Outlook

#### 预期结果
- [ ] Outlook 中事件已删除

---

### 测试 2.12: 从 App 删除重复事件 - This Event Only

1. 在 App 中打开 "App Daily Task" 的第 2 天
2. 选择 "Delete this event"
3. 验证 Outlook

#### 预期结果
- [ ] Outlook 中只有第 2 天的事件被删除

---

### 测试 2.13: 从 App 删除重复事件 - This and Future Events

1. 在 App 中打开 "App Weekly Meeting" 的某一天
2. 选择 "Delete this and future events"
3. 验证 Outlook

#### 预期结果
- [ ] Outlook 中删除日期及之后的事件都消失

---

### 测试 2.14: 从 App 删除重复事件 - All Events

1. 在 App 中打开 "App Yearly Review"
2. 选择 "Delete all events"
3. 验证 Outlook

#### 预期结果
- [ ] Outlook 中整个系列都被删除

---

## 三、边界情况测试

### 测试 3.1: Token 刷新

1. 等待 access_token 过期（约 1 小时后）
2. 触发同步
3. 验证同步是否正常工作

#### 预期结果
- [ ] 系统自动刷新 token
- [ ] 同步继续正常工作

---

### 测试 3.2: 网络断开恢复

1. 断开网络
2. 在 App 中创建事件
3. 恢复网络
4. 触发同步

#### 预期结果
- [ ] 事件在网络恢复后成功同步到 Outlook

---

### 测试 3.3: 大量事件同步

1. 在 Outlook 中批量创建 50+ 事件
2. 触发同步
3. 验证所有事件都同步到 App

#### 预期结果
- [ ] 所有事件都正确同步
- [ ] 性能可接受（< 1 分钟）

---

## 测试结果记录

| 测试编号 | 测试项目 | 状态 | 备注 |
|---------|---------|------|------|
| 1.1 | 基本事件同步 | ⬜ | |
| 1.2 | 全天事件同步 | ⬜ | |
| 1.3 | 重复事件 - Daily | ⬜ | |
| 1.4 | 重复事件 - Weekly | ⬜ | |
| 1.5 | 重复事件 - Monthly | ⬜ | |
| 1.6 | 重复事件 - Yearly | ⬜ | |
| 1.7 | 修改事件 | ⬜ | |
| 1.8 | 修改重复 - This Only | ⬜ | |
| 1.9 | 修改重复 - This & Future | ⬜ | |
| 1.10 | 删除单个事件 | ⬜ | |
| 1.11 | 删除重复 - This Only | ⬜ | |
| 1.12 | 删除重复 - This & Future | ⬜ | |
| 1.13 | 删除重复 - All | ⬜ | |
| 2.1 | App 添加普通事件 | ⬜ | |
| 2.2 | App 添加全天事件 | ⬜ | |
| 2.3 | App 添加 Daily 重复 | ⬜ | |
| 2.4 | App 添加 Weekly 重复 | ⬜ | |
| 2.5 | App 添加 Monthly 重复 | ⬜ | |
| 2.6 | App 添加 Yearly 重复 | ⬜ | |
| 2.7 | App 修改基本信息 | ⬜ | |
| 2.8 | App 修改重复 - This Only | ⬜ | |
| 2.9 | App 修改重复 - This & Future | ⬜ | |
| 2.10 | App 修改重复 - All | ⬜ | |
| 2.11 | App 删除单个事件 | ⬜ | |
| 2.12 | App 删除重复 - This Only | ⬜ | |
| 2.13 | App 删除重复 - This & Future | ⬜ | |
| 2.14 | App 删除重复 - All | ⬜ | |
| 3.1 | Token 刷新 | ⬜ | |
| 3.2 | 网络断开恢复 | ⬜ | |
| 3.3 | 大量事件同步 | ⬜ | |

---

## 调试命令

### 查看 Go Syncer 日志
```bash
# 如果是 systemd 服务
sudo journalctl -u outlook_syncer -f

# 如果是直接运行
# 日志直接输出到终端
```

### 查看 Django 日志
```bash
tail -f server/logs/django.log
```

### 手动触发同步 (Django Shell)
```python
from pronext.calendar.options import sync_calendar
from pronext.calendar.models import SyncedCalendar
from pronext.device.models import UserDeviceRel

# 获取 Outlook 日历
synced = SyncedCalendar.objects.filter(calendar_type=2, id={ID}).first()

# 获取关联用户
rels = UserDeviceRel.objects.filter(device_id=synced.user_id)
rel_user_ids = [rel.user_id for rel in rels]

# 同步
result = sync_calendar(synced, rel_user_ids)
print(f"Sync result: {result}")
```

### 检查同步的事件
```python
from pronext.calendar.models import Event, SyncedCalendar

synced = SyncedCalendar.objects.get(id={ID})
events = Event.objects.filter(synced_calendar=synced).order_by('-start_at')

for e in events[:10]:
    print(f"{e.title} | {e.start_at or e.start_date} | {e.recurrence or 'no repeat'}")
```

### 检查 Delta Link
```python
from pronext.calendar.models import SyncedCalendar

synced = SyncedCalendar.objects.get(id={ID})
print(f"Delta Link: {synced.outlook_delta_link[:100] if synced.outlook_delta_link else 'None'}...")
```
