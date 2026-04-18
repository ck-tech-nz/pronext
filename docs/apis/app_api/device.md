# Device


## 注册设备

用户输入一个名称，后端需要检查是否已存在, 存在则不给注册

**URL:** `POST` device/register

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
name | string | 是 | name, max:32

**输出:**

字段 | 类型 | 说明
---|---|---
code | int | 激活码, 10分钟有效


## 添加设备

用户通过临时分享添加设备

**URL:** `POST` device/add

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
link | string | 是 | 分享链接, max:500

**输出:**

字段 | 类型 | 说明
---|---|---
code | int | 激活码, 10分钟有效


## 移除设备

只是移除，并不是真删除

**URL:** `POST` device/<device_id\>/remove

**输入:** 无

**输出:** 无


## 获取设备列表

按添加时间倒序返回用户所有的设备，不分页

分享设备页面也调用此接口

**URL:** `GET` device/list

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
id  | int | id
name | string | 设备名称
email | string | 设备email
code | int | 激活码, 10分钟有效
is_active | bool | 是否已激活
link | string | 分享链接
link_expired_at | string | 分享链接过期时间, 格式2024-06-29T00:00:00 +8000


## 获取设备主页信息

**URL:** `GET` device/<device_id\>/home?date=

**Query:**

字段 | 必填 | 说明
---|---|---
date | 是 | 日期，2024-06-29T00:00:00 +0800

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
<del>events</del> | List<Event\> | 当天event事件，删除，调用event接口获取此数据
<del>event_count</del> | int | 当天event的数量，删除，用events.length
chore_count | int | 当天chore数量
photo_count | int | 图片媒体数量
list_count | int | todolist数量


## 刷新设备分享链接

**URL:** `POST` device/<device_id\>/refresh_link

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
link | string | 分享链接
link_expired_at | string | 分享链接过期时间, 格式2024-06-29T00:00:00 +8000


## 清除设备分享链接

**URL:** `POST` device/<device_id\>/clear_link

**输入:** 无

**输出:** 无
