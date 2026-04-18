# Photo


## Media

字段 | 类型 | 说明
---|---|---
id          | long |
url         | string | url
media_type  | int | 类型, 1:img, 2:video


## 获取media列表

**URL:** `GET` photo/device/<device_id\>/list?page=1&size=20

**Query:**

字段 | 必填 | 说明
---|---|---
page | 否 | 页码，默认1 
size | 否 | 每页大小，默认20

**输出:** list<[Media](#media)\>


## 添加media

先走【获取上传文件链接】 -> 【上传文件】流程，得到url后，再添加media

**URL:** `POST` photo/device/<device_id\>/add

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
url  | string | 是 | url, max:1000
media_type | int | 是 | 类型, 1:img, 2:video

**输出:** 

字段 | 类型 | 说明
---|---|---
id | long | 分类id


## 删除media

**URL:** `POST` photo/device/<device_id\>/delete

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
ids  | list<long\> | 是 | id列表

**输出:** 无


## 复制media到其他device

**后端：是否根据url进行排重?**

**URL:** `POST` photo/device/<device_id\>/copy_to

**输入:** 

字段 | 类型 | 必填 | 说明
---|---|---|---
medias | list<Media\> | 是 | media列表
device_ids  | list<long\> | 是 | device id列表

**输出:** 无
