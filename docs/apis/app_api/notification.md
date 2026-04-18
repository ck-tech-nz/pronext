# Notification

## 获取通知列表

按时间倒序返回， 分页

**URL:** `GET` notification/list?page=1&size=20

**Query:**

字段 | 必填 | 说明
---|---|---
page | 否 | 页码，默认1 
size | 否 | 每页大小，默认20

**输出:** list<Notification\>

## Notification

字段 | 类型 | 说明
---|---|---
id      | long   |
title   | string | title
content | string | 内容
created_at | string | 创建时间, 格式2024-06-29T00:00:00 +8000


## 获取未读通知数量

**URL:** `GET` notification/unread_count

**Query:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
unread_count | int | 未读数量
