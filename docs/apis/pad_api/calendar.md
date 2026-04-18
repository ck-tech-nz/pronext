# Calendar


## Category

字段 | 类型 | 说明
---|---|---
id    | long | id
name  | string | 分类名称
color | string | 分类颜色, 如: #333333
is_dinner_plan | bool | 是否是dinner plan类型, 只读
disable | bool | 是否禁用


## Event

字段 | 类型 | 说明
---|---|---
id           | long | id
event_type   | int | event类型，0:EVENT, 1:DINNER
category_ids   | list<long\> | 所属分类，列表
title        | string | 标题
start_at     | string | 开始时间, 2024-06-29T15:51:23+8000
end_at       | string | 结束时间, 2024-06-29T15:51:23+8000
synced_calendar_id | long | 同步日历id
repeat_every | int | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 重复类型, 0Day,1Week,2Month
repeat_until | string | 重复截止日期, 格式是2024-06-29T00:00:00+8000
repeats      | list<string\> | repeat_flag重复标识列表，格式为`start__end`，需要将这个列表转换成event列表，<br>转换时解析出flag里的start和end，替换掉原event的start_at和end_at，再把repeat_flag赋值给event以便后用
repeat_flag  | string | 原事件的repeat_flag(重复标识)，格式为`start__end`
repeat_deleted_origin | bool | 是否已删除重复事件的原事件，如果是，转换event列表时，需要排除原事件
has_remind   | bool | 是否提醒
remind_immediately | bool | 是否开始时提醒
remind_before      | int  | 在开始前多少分钟提醒
remind_play_sound  | bool | 是否播放声音


## SyncedCalendar

字段 | 类型 | 说明
---|---|---
id    | long | id
calendar_type  | int | 日历类型 <br>1:google, 2:outlook(/hotmail/live), 3:iCloud <br>4:Cozi, 5:Yahoo, 6:calendar url, 7:us holidays
synced_style | int | 同步风格，1:单向同步，2:双向同步，当前只有google支持双向同步
name  | string | 日历名称
email | string | 邮箱，也是google calendar的id
link  | string | 链接，如果是通过URL同步的，存在Link
remark | string | 备注


## 获取分类列表

按创建时间倒序排序

**URL:** `GET` calendar/category/list

**Query:** 无

**输出:** list<[Category](#category)\>


## 添加分类

**URL:** `POST` calendar/category/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 分类名称，用户内唯一，max:80
color | string | 是 | 分类颜色，如: #333333

**输出:**

字段 | 类型 | 说明
---|---|---
id | long | 分类id


## 更新分类

**URL:** `POST` calendar/category/<category_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 分类名称，用户内唯一，max:80
color | string | 是 | 分类颜色，如: #333333

**输出:** 无


## 获取Event列表

按时间升序排序，不分页

**URL:** `GET` calendar/event/list?start_at=&end_at=

**Query:**

字段 | 必填 | 说明
---|---|---
start_at | 是 | 查询开始时间, 2024-06-29T15:51:23+0800
end_at   | 是 | 查询结束时间, 2024-06-29T15:51:23+0800
with_remind | 否 | 是否用于remind，默认否，如果是，会触发remind_event心跳

**输出:** list<[Event](#event)\>


## 添加Event

**URL:** `POST` calendar/event/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
title        | string | 是 | 标题:300
event_type   | int    | 是 | event类型，0:EVENT, 1:DINNER
category_ids | list<long\> | 是 | 分类id列表
start_at     | string | 是 | 开始时间, 2024-06-29T15:51:23+0800
end_at       | string | 是 | 结束时间, 2024-06-29T15:51:23+0800
synced_calender_id    | long   | 否 | 同步日历id
repeat_every | int | 否 | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 否 | 重复类型, 0:Day, 1:Week, 2:Month
repeat_until | string | 否 | 重复截止日期, 格式是2024-06-29T00:00:00 +8000

**输出:**

字段 | 类型 | 说明
---|---|---
id | long | event id


## 更新Event

**URL:** `POST` calendar/event/<event_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
title        | string | 是 | 标题:300
category_ids | list<long\> | 是 | 分类id列表
start_at     | string | 是 | 开始时间, 2024-06-29T15:51:23+0800
end_at       | string | 是 | 结束时间, 2024-06-29T15:51:23+0800
repeat_every | int | 是 | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 是 | 重复类型, 0:Day, 1:Week, 2:Month
repeat_until | string | 否 | 重复截止日期, 格式是2024-06-29T00:00:00+8000
has_remind   | bool | 否 |  是否提醒
remind_immediately | bool | 否 | 是否开始时提醒
remind_before      | int  | 否 | 在开始前多少分钟提醒
remind_play_sound  | bool | 否 | 是否播放声音
change_type        | int  | 是 | 修改类型，0:this, 1:all, 2:this and future
repeat_flag        | string | 否 | 如果是重复事件, 此参数`必填`，从父repeats里取的flag

**输出:** 无


## 删除Event

**URL:** `POST` calendar/event/<event_id\>/delete

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
change_type     | int    | 是 | 修改类型，0:this, 1:all, 2:this and future
repeat_flag     | string | 否 | 如果是重复事件, 此参数`必填`，从父repeats里取的flag

**输出:** 无



## 获取双向同步第三方日历列表

**URL:** `get` calendar/synced_calendar/two_ways

**输入:** 无

**输出:** list<[SyncedCalendar](#syncedcalendar)\>


## 获取第三方日历详情

**URL:** `get` calendar/synced_calendar/<synced_calendar_id\>/detail

**输入:** 无

**输出:** [SyncedCalendar](#syncedcalendar)
