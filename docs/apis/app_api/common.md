# Common


## 获取上传文件链接

**URL:** `POST` common/presigned_upload_url

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 文件名, max:1000
hash  | int | 是 | 文件hash值，max: 100, 一般md5前16位

**输出:**

字段 | 类型 | 说明
---|---|---
url | string | 文件url， 如果文件已上传过，返回url，不用再次上传
upload_url | string | 上传url，将文件Post到这个url，和form_data一起
form_data | object | 上传FormData
