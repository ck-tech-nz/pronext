# Chore


## Category

字段 | 类型 | 说明
---|---|---
id    | long |
name  | string | 分类名称
color | string | 分类颜色，如: #333333
hidden | bool  | 是否隐藏/禁用


## Chore

字段 | 类型 | 说明
---|---|---
id           | long |
category_ids   | list<long\> | 所属分类id列表
content      | string | 内容
expired_at   | string | 到期时间, 2024-06-29T15:51:23+0800
completed    | bool | 是否完成
repeat_every | int | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 重复类型, 0Day,1Week,2Month
repeat_until | string | 重复截止日期, 格式是2024-06-29T00:00:00+8000
repeat_flag  | string | 如果是重复事件, 会有此值，用于修改和删除等接口


## 获取事务分类列表

按创建时间倒序排序

**URL:** `GET` chore/device/<device_id\>/category/list

**Query:** 无

**输出:** list<[Category](#category)\>


## 获取事务分类详情

**URL:** `GET` chore/device/<device_id\>/category/<category_id\>/detail

**Query:** 无

**输出:** [Category](#category)


## 添加事务分类

**URL:** `POST` chore/device/<device_id\>/category/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 分类名称，用户内唯一，max:80
color | string | 是 | 分类颜色，如: #333333

**输出:** 

字段 | 类型 | 说明
---|---|---
id | long | 分类id


## 更新事务分类

**URL:** `POST` chore/device/<device_id\>/category/<category_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 分类名称，用户内唯一，max:80
color | string | 是 | 分类颜色，如: #333333
hidden | bool | 是 | 是否隐藏/禁用

**输出:** 无

## 删除分类

**URL:** `POST` chore/device/<device_id\>/category/<category_id\>/delete

**输入:** 无

**输出:** 无


## 获取事务列表

按时间查询事务列表，不分页，**客户端需要按expired_at升序重新排序**

**加上： 所有expired_at为空且未完成的事务**

**URL:** `GET` chore/device/<device_id\>/list?date=&include_expired=

**Query:**

字段 | 必填 | 说明
---|---|---
date | 是 | 日期，2024-06-29T00:00:00+0800，如果不填，返回空列表
include_expired | 否 | 是否包含已过期的事务，如果获取的是今天的事务，此值要设置为true

**输出:** list<Chore\>


## 获取事务详情

**URL:** `GET` chore/device/<device_id\>/<chore_id\>/detail

**Query:** 无

**输出:** [Chore](#chore)


## 添加事务

**URL:** `POST` chore/device/<device_id\>/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
content      | string | 是 | 内容，max:300
category_ids | list<int\> | 是 | 分类id列表
expired_at   | string | 否 | 到期时间, 2024-06-29T00:00:00+0800
repeat_every | int | 否 | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 否 | 重复类型, 0:Day, 1:Week, 2:Month
repeat_until | string | 否 | 重复截止日期, 格式是2024-06-29T00:00:00+800


**输出:**

字段 | 类型 | 说明
---|---|---
id | long | 事务id


## 更新事务

**URL:** `POST` chore/device/<device_id\>/<chore_id\>/update

**输入:**


字段 | 类型 | 必填 | 说明
---|---|---|---
content      | string | 是 | 内容，max:300
category_ids | list<long\> | 是 | 分类id列表
expired_at   | string | 否 | 到期时间, 2024-06-29T00:00:00+0800
repeat_every | int | 否 | 重复周期，还用于判断是否有repeat，>0表示有
repeat_type  | int | 否 | 重复类型, 0:Day, 1:Week, 2:Month
repeat_until | string | 否 | 重复截止日期, 格式是2024-06-29T00:00:00+8000
change_type  | int  | 是 | 修改类型，0:this, 1:all, 2:this and future
repeat_flag  | string | 否 | 如果是重复事件, 此值必填，chore会回传此值

**输出:** 无


## 完成事务

**URL:** `POST` chore/device/<device_id\>/<chore_id\>/complete

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
completed | bool | 是 | 是否完成
repeat_flag | string | 否 | 如果是重复事件, 此值必填，chore会回传此值

**输出:** 无


## 删除事务

**URL:** `POST` chore/device/<device_id\>/<chore_id\>/delete

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
change_type  | int    | 是 | 修改类型，0:this, 1:all, 2:this and future
repeat_flag  | string | 否 | 如果是重复事件, 此值必填，chore会回传此值

**输出:** 无
