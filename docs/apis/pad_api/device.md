# Auth


## 激活设备

无需授权认证

**URL:** `POST` device/activation

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
code | string | 是 | 6位数字

**输出:**

字段 | 类型 | 说明
---|---|---
access | string | access jwt token


## 重置设备

**URL:** `POST` device/reset

**输入:** 无

**输出:** 无


## 获取设备信息

**URL:** `GET` device/info

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
device_name | string | 设备名称
owner_username | string | 设备所有者用户名
