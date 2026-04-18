# To Do List


## Category

字段 | 类型 | 说明
---|---|---
id    | long |
name  | string | 分类名称
color | string | 分类颜色，如: #333333
category_type | int  | 类型, 0:Other, 1:Shopping, 2:To Do


## Todo

字段 | 类型 | 说明
---|---|---
id           | long |
content      | string | 内容
completed    | bool | 是否完成


## 获取分类(List)列表

**URL:** `GET` todo/device/<device_id\>/category/list

**Query:** 无

**输出:** list<[Category](#category)\>


## 获取分类(List)详情

**URL:** `GET` todo/device/<device_id\>/category/<category_id\>/detail

**Query:** 无

**输出:** [Category](#category)


## 添加分类(List)

**URL:** `POST` todo/device/<device_id\>/category/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 是 | 分类名称，用户内唯一，max:80
color | string | 是 | 分类颜色，如: #333333
category_type | int | 是 | 类型, 0:Other, 1:Shopping, 2:To Do

**输出:** 

字段 | 类型 | 说明
---|---|---
id | long | 分类id


## 更新分类(List)

**URL:** `POST` todo/device/<device_id\>/category/<category_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 否 | 分类名称，用户内唯一，max:80
color | string | 否 | 分类颜色，如: #333333
category_type | int | 否 | 类型, 0:Other, 1:Shopping, 2:To Do

**输出:** 无


## 删除分类(List)

**删除分类，同时也把这个分类下的所有todo删除**

**URL:** `POST` todo/device/<device_id\>/category/<category_id\>/delete

**输入:** 无

**输出:** 无


## 获取Todo列表

根据category_id分组列出所有todo，不分页

**URL:** `POST` todo/device/<device_id\>/group_list

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
category_ids | list<long\> | 是 | category ids

**输出:** {category_id: list<Todo\>}


## 添加Todo

**URL:** `POST` todo/device/<device_id\>/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
category_id | int | 是 | 分类id
content | string | 是 | 内容，max:300

**输出:**

字段 | 类型 | 说明
---|---|---
id | long | todo id


## 编辑Todo

**URL:** `POST` todo/device/<device_id\>/<todo_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
content | string | 是 | 内容，max:300

**输出:** 无


## 完成Todo

**URL:** `POST` todo/device/<device_id\>/<todo_id\>/complete

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
completed | bool | 是 | 是否完成

**输出:** 无


## 删除Todo

**URL:** `POST` todo/device/<device_id\>/<todo_id\>/delete

**输入:** 无

**输出:** 无
