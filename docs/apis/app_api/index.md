# Base


## 更新说明

**版本：** v1.0.0

**更新日期：** 2024-07-24

版本 | 日期 | 修订人 | 说明
---|---|---|---
1.0.0 | 2024-07-24 | eric | 初稿


## 接口约定

**content-type：** application/json

**传输协议：** JSON

**Base Test URL：** https://api.pronext.xpent.cn/app-api/

### Headers

字段 | 必填 | 说明
---|---|---
Timestamp     | 是 | 当前时间戳, 精确到秒
Signature     | 是 | 签名
Authorization | 否 | 授权Bearer token, jwt, 包含数据: {user_id: 1, email: "x@xx.com"}

**签名过程：注：Vue下不校验签名，可能不填Timestamp和Signature**

    1. 原始数据：appBuildNum|deviceId|systemVersion|Timestamp
    2. 将1数据做AES加密， key: OYvYQQTH2QCvq9ls, iv: pRCBICUoOJ6B1I65, 得出密文
    3. 将2数据Base64，得出Signature

### 输出数据标准

* 用http标准返回码做为成功/失败依据
* 所有成功/失败返回的body都应该是{}-Object, 不能返回[]--Array

通用字段:

字段 | 类型 | 说明
---|---|---
data    | object | 数据，和list互斥，返回list时不会返回data
list    | array  | 数组数据
total   | int    | 和list成对返回，总数
msg     | object<key: msg\> | 提示消息，正常情况下返回{"default": msg}<br>POST Form时，可能会返回多个key: msg，对应每个field
