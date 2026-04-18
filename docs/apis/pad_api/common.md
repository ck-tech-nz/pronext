# Common


## 检查更新

如果有更新，返回apk_url，下载后再安装

**URL:** `POST` common/check_update

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
apk_url | string | apk url


## 心跳

**URL:** `POST` common/heartbeat

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
event_cate | bool | 是否需要刷新Event类型列表
event | bool | 是否需要刷新Event列表
remind_event | bool | 是否需要刷新提醒列表
chore_cate | bool | 是否需要刷新Chore类型列表
chore | bool | 是否需要刷新Chore列表
photo | bool | 是否需要刷新Photo列表
access_token | string | 如果此字段有值，更新当前auth token
