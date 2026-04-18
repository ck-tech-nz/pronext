# Photo


## Media

字段 | 类型 | 说明
---|---|---
id          | long |
url         | string | url
media_type  | int | 类型， 1:img, 2:video


## 获取media列表

**URL:** `GET` photo/list

**Query:** 无

**输出:** list<[Media](#media)\>


## 删除media

**URL:** `POST` photo/delete

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
ids  | list<long\> | 是 | id列表

**输出:** 无
