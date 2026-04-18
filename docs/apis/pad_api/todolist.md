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


## 获取分类列表

**URL:** `GET` todo/category/list

**Query:** 无

**输出:** list<[Category](#category)\>


## 添加分类

**URL:** `POST` todo/category/add

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


## 更新分类

**URL:** `POST` todo/category/<category_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
name  | string | 否 | 分类名称，用户内唯一，max:80
color | string | 否 | 分类颜色，如: #333333
category_type | int | 否 | 类型, 0:Other, 1:Shopping, 2:To Do

**输出:** 无


## 获取Todo列表

列出单个category的所有todo，不分页

**URL:** `GET` todo/<category_id\>/list

**输出:** list<Todo\>


## 添加Todo

**URL:** `POST` todo/<category_id\>/add

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
content      | string | 是 | 内容，max:300

**输出:**

字段 | 类型 | 说明
---|---|---
id | long | todo id


## 更新Todo

部分更新(Patch)，是否完成也调用此接口，只用传completed

**URL:** `POST` todo/<todo_id\>/update

**输入:**

字段 | 类型 | 必填 | 说明
---|---|---|---
completed | bool | 否 | 是否完成

**输出:** 无
