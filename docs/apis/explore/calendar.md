# 日历活动

## 1. 属性

字段 | 类型  | 说明
---- | ---- | ----
user               | User           | 关联用户
id                 | long           | id
event_type         | EventType<int> | 活动类型 [2.1](#2.1)
category_ids       | list<long\>    | 活动分类，id列表 [2.2](#2.2)
title              | string         | 标题
start_at           | string         | 开始时间, 2024-06-29T15:51:23 +8000
end_at             | string         | 结束时间, 2024-06-29T15:51:23 +8000
synced_calendar    | SyncedCalendar | 同步日历
repeat_every       | int            | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type        | int            | 重复类型, 0Day,1Week,2Month
repeat_until       | string         | 重复截止日期, 格式是2024-06-29T00:00:00 +8000
has_remind         | bool           | 是否提醒
remind_immediately | bool           | 是否开始时提醒
remind_before      | int            | 在开始前多少分钟提醒
remind_play_sound  | bool           | 是否播放声音

## 2. 详细介绍

### 2.1 活动类型

类型 | 值 | 说明
---- | ---- | ----
EVENT  | 0 | 普通活动
DINNER | 1 | 晚餐活动，是普通活动的简化版，只有title, start_at的repeat相关参数；<br>分类不可设置，有固定的分类`dinner plan`

### 2.2 活动分类

## 3. 更新活动

### 3.1 更新普通活动

### 3.2 更新周期性活动

当更新周期性活动时，必要参数是活动的`开始时间`和`更新类型`

更新类型有3种:

类型 | 值 | 说明
---- | ---- | ----
THIS  | 0 | 只更新当前一条活动
ALL | 1 | 更新所有活动
AND_FUTURE | 2 | 更新当前一条和未来所有活动

**THIS处理逻辑:**

插入一条与周期性活动关联的新活动；如果是google two_way活动，