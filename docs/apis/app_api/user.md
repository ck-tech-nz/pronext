# User


## 检查Email是否已注册

无需登录

**URL:** `POST` user/check_email

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
email | string | 是 | max:128

**输出:** 无


## 注册

无需登录

**URL:** `POST` user/register

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
email | string | 是 | max:128
name | string | 是 | max:20
phone | string | 否 | max:20
password | string | 是 | max:128

**输出:**

字段 | 类型 | 说明
---|---|---
token | string | Bearer token


## 登录

无需登录

**URL:** `POST` user/login

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
email | string | 是 | max:128
password | string | 是 | max:128

**输出:**

字段 | 类型 | 说明
---|---|---
token | string | Bearer token


## 重置密码

无需登录

**URL:** `POST` user/rest_password

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
email | string | 是 | max:128

**输出:** 无


## 获取用户信息

**URL:** `GET` user/profile

**输入:** 无

**输出:**

字段 | 类型 | 说明
---|---|---
email | string |
name | string |
phone | string |
birthday | string | 生日，格式1990-02-21
notification_by_email | bool | 是否通过email接收通知
marketing_promotion | bool | 是否接收推广通知


## 更新用户信息

**URL:** `POST` user/profile/update

**部分更新，意思是结合页面，修改一个字段保存一次**

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name | string | 否 | max:20
phone | string | 否 | max:20
birthday | string | 否 | max:20，格式1990-02-21
notification_by_email | bool | 否 | 是否通过email接收通知
marketing_promotion | bool | 否 | 是否接收推广通知

**输出:** 无
