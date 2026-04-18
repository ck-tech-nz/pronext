# Chores -> Tasks: rrule 迁移与架构升级计划

## Context

Chore 模块使用自定义的 `repeat_every` + `repeat_type` 整数组合表示重复规则，无本地数据库，每次请求都依赖后端展开 rrule。而 Meal 模块已采用 RFC 5545 rrule + Room 本地数据库 + 本地 rrule 展开的新架构。

当前正在进行 Chore UI 升级（Flutter 替代 H5）。与其给旧 Chore 模块打补丁，不如新建 Task 模块完全继承 Meal 的最佳实践，同时保留旧 Chore 模块供未升级客户端使用。

## 决策记录

- **新建 Task app 取代 Chore app**：不修改旧 chore 表，新建 task 表，数据迁移脚本将 chore 数据复制并转换到 task。
- **completeds 格式**：改为日期字符串（`"2025-01-15"`），与 exdates 统一。
- **byday 支持**：这次一起加。Flutter UI 增加星期几多选控件（weekly 重复时显示）。

---

## 架构现状对比

### 三端对比：Chore vs Meal

| | Chore（旧架构） | Meal（新架构/目标） |
| --- | --- | --- |
| **重复规则存储** | `repeat_every` (int) + `repeat_type` (enum 0-3) | `rrule` CharField (RFC 5545) |
| **排除日期** | `repeat_excludes` (JSON, 时间戳字符串) | `exdates` (JSON, 日期字符串) |
| **展开位置** | 仅服务端 `find_fitted_repeat()` | 服务端(App) + 本地(Pad) |
| **表达能力** | 仅 every N days/weeks/months/years | 支持指定星期几、第N个星期几等 |
| **版本控制** | 无 | `version` 字段 + 乐观锁 |

### Pad 端对比

| | Chore Pad | Meal Pad（目标） |
| --- | --- | --- |
| **本地存储** | 无（纯内存 + MMKV 缓存 category） | Room DB（categories, recipes, meals 三表） |
| **离线支持** | 无，切换日期就要请求 API | 有，Room 提供本地缓存 |
| **rrule 展开** | 后端展开，返回扁平列表 | 本地 `RRuleParser` (dmfs/lib-recur) |
| **同步策略** | 每次 pull | 双向同步 + SyncStatus + 乐观更新 |
| **冲突处理** | 无 | version 冲突检测 + 409 处理 |

### 已有的可复用基础设施

| 组件 | 位置 | 说明 |
| --- | --- | --- |
| `BaseCategory` | `meal/models.py:13` | 已有的 Django 抽象基类（name, color, timestamps） |
| `ChangeType` enum | `meal/models.py`, `chore/models.py`, `calendar/models.py` | 三处完全相同的枚举，应提取 |
| `rrule_utils.py` | `meal/rrule_utils.py` | `repeat_to_rrule()` / `rrule_to_repeat()` 纯函数 |
| `recurrence.py` | `meal/recurrence.py` | 服务端 rrule 展开，用 `ical` 库 |
| `RepeatSerializer` | `meal/serializers.py:55-66` | freq/interval/until/byday/bymonthday/bysetpos |
| `RRuleParser` | Pad `utils/RRuleParser.kt` | Pad 端 rrule 生成 + 展开，用 dmfs/lib-recur |
| `IRepeat` 接口 | Pad `common/RepeatModel.kt` | Chore model 已实现此接口 |
| `MealEntity` 模式 | Pad `database/entities/MealEntity.kt` | Room entity + SyncStatus + 负数本地ID |
| `MealRepository` | Pad `modules/meal/MealManager.kt` | 完整的 CRUD + 同步 + 乐观更新模板 |

---

## 方案：新建 Task App + 新建 Base App

### 为什么不直接改 Chore

1. **保留回滚能力**：chore 表和旧 API 原封不动，出问题可以立即回退。
2. **向后兼容零风险**：旧版 App (H5 Vue) 和旧版 Pad 继续用 chore API，互不干扰。
3. **更干净的代码**：task 模块从零开始用正确的架构，不需要双写兼容逻辑。
4. **Django abstract model 不会产生 Meal 的新 migration**：如果抽象基类的字段与 Meal 现有字段完全一致，`makemigrations` 不会改变 meal 表。

### 为什么新建 base app 而非放 common

`common` app 是具体业务模块（H5Version、AppVersion、PadApk、Beat、UpdateResult），职责是版本管理和设备通信，不适合放抽象基类。新建 `base` app 专门存放：
- 抽象 model 基类（无数据库表）
- 纯工具函数（rrule_utils、recurrence_utils）
- 公共 serializer

### 方案总览

```text
                     pronext.base (新建 base app)
                     |-- ChangeType enum
                     |-- rrule_utils.py (从 meal 移入)
                     |-- recurrence.py  (从 meal 移入)
                     |-- RepeatSerializer
                     |-- BaseCategory (从 meal 移入)
                     |-- BaseRecurrableModel (新增抽象基类)
                            |
              +-------------+-------------+
              |                           |
        pronext.meal                pronext.task (新建)
        (继承, 无 migration)        (继承, 新 migration)
              |                           |
        meal 表不变                 task + task_category 新表
```

---

## Django 后端

### Phase 1: 新建 `pronext.base` App + 提取公共层

**1a. 公共抽象基类**

```python
# pronext/base/models.py (新文件)

class ChangeType(models.IntegerChoices):
    THIS = 0, "this"
    ALL = 1, "all"
    AND_FUTURE = 2, "and future"


class BaseCategory(models.Model):
    """从 meal/models.py 的 BaseCategory 移入"""
    name = models.CharField(max_length=80)
    color = models.CharField(max_length=10)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True


class BaseRecurrableModel(models.Model):
    """rrule-based 重复模型的公共基类"""
    rrule = models.CharField(max_length=512, blank=True, null=True)
    exdates = models.JSONField(default=list, blank=True, null=True)
    version = models.PositiveSmallIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True

    @property
    def has_repeat(self):
        return bool(self.rrule)
```

**1b. 公共工具函数**

从 `meal/rrule_utils.py` 移入 `base/rrule_utils.py`：
- `repeat_to_rrule(repeat)` -- repeat dict -> rrule 字符串
- `rrule_to_repeat(rrule)` -- rrule 字符串 -> repeat dict
- `update_rrule_until(rrule, until_date)` -- 修改 UNTIL
- `weekday_indices_to_byday(indices)` / `byday_to_weekday_indices(byday)`

从 `meal/recurrence.py` 移入 `base/recurrence_utils.py`：
- `get_occurrences(start_date, rrule, exdates, range_start, range_end)` -- 通用 rrule 展开
- `parse_until_from_rrule(rrule)` / `update_rrule_until(rrule, until_date)`

公共 serializer 移入 `base/serializers.py`：
- `RepeatSerializer`（freq, interval, until, byday, bymonthday, bysetpos）

**1c. Meal app 适配**

- `meal/models.py`: `Meal` 继承 `BaseRecurrableModel`，`Category` 继承 `BaseCategory`
- 删除 Meal 自己的 `ChangeType`、`BaseCategory` 定义，改为从 `base` 导入
- 字段名和类型与现有完全一致 -> **不产生新的 meal migration**（Django 只会记录 bases 变更，不改表结构）
- 删除 `meal/rrule_utils.py` 和 `meal/recurrence.py`，meal 内部 import 改为从 `base` 导入

### Phase 2: 新建 `pronext.task` App

**2a. Task Model**

```python
# pronext/task/models.py

from pronext.base.models import BaseRecurrableModel, BaseCategory, ChangeType

class TaskCategory(BaseCategory):
    user = models.ForeignKey(AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="task_categories")
    hidden = models.BooleanField(default=False)

    class Meta:
        unique_together = ("user", "name")


class Task(BaseRecurrableModel):
    user = models.ForeignKey(AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tasks")
    category = models.ForeignKey(TaskCategory, on_delete=models.CASCADE, related_name="tasks")
    content = models.CharField(max_length=500)
    due_date = models.DateField()                          # 对应 meal 的 plan_date
    due_time = models.TimeField(null=True, blank=True)     # null = 全天任务
    completeds = models.JSONField(default=list, blank=True) # 日期字符串列表
    # 继承自 BaseRecurrableModel: rrule, exdates, version, created_at, updated_at
```

对比旧 Chore model 的关键改进：
- `category` 改为 ForeignKey（旧 chore 用 `category_ids` JSONField，创建时按 category 拆成多条记录）
- `due_date` + `due_time` 替代 `expired_at` DateTime（更清晰，方便 rrule 按日期展开）
- `rrule` + `exdates` 替代 `repeat_every`/`repeat_type`/`repeat_until`/`repeat_excludes`
- `completeds` 用日期字符串列表（如 `["2025-01-15"]`）替代时间戳字符串

**2b. Task 业务逻辑**

`pronext/task/options.py` — 从 `meal/options.py` 复制结构并适配：
- `get_tasks()` / `get_tasks_for_sync()` -- 双路径（App 服务端展开 / Pad 返回原始数据）
- `add_task()` / `update_task()` / `delete_task()` -- THIS/ALL/AND_FUTURE 逻辑
- `complete_task()` -- 用日期字符串标记完成

**2c. Task Serializers + Viewsets**

- `viewset_app.py` -- App (Flutter) 端接口，服务端展开 rrule
- `viewset_pad.py` -- Pad 端接口，返回原始 rrule 供本地展开
- 复用 `base` 的 `RepeatSerializer`

**2d. 数据迁移脚本**

Django management command `migrate_chores_to_tasks`：

```text
For each Chore where repeat_every > 0:
    rrule = convert(repeat_every, repeat_type) -> "FREQ=DAILY;INTERVAL=2"
    if repeat_until: rrule += ";UNTIL=YYYYMMDD"
    exdates = [parse_timestamp(ts).date().isoformat() for ts in repeat_excludes]
    completeds = [parse_timestamp(ts).date().isoformat() for ts in completeds]

For each Chore where repeat_every == 0:
    rrule = None, exdates = []
    completeds = ["self"] if "self" in completeds else []
      -> 改为 [due_date.isoformat()] if completed

For each Chore.category_ids -> find or create TaskCategory
    Create Task record with FK to TaskCategory
```

运行时机：后端部署后、新客户端发布前的夜间窗口。

---

## Pad 端 (Android/Kotlin)

### 复用 Meal 基础设施

Pad 端的 Meal 模块已经实现了完整的 Room + 同步架构，Task 模块可以直接复用：

**可直接复用（无需修改）：**
- `RRuleParser.kt` -- rrule 生成 + 展开（已在 `utils/` 共享目录）
- `SyncStatus` enum -- SYNCED / PENDING_CREATE / PENDING_UPDATE / PENDING_DELETE
- `IRepeat` 接口 -- Chore 已实现，Task 继续实现
- `ChangeConfirm` 组件 -- THIS/ALL/AND_FUTURE 选择对话框
- Signal 系统、Beat 系统、Net 网络层

**需要新建（参照 Meal 模板）：**

| 新文件 | 参照 | 说明 |
| --- | --- | --- |
| `TaskDatabase.kt` | `MealDatabase.kt` | Room DB，两表：task_categories, tasks |
| `TaskEntity.kt` | `MealEntity.kt` | Room entity + rrule + exdates + syncStatus |
| `TaskCategoryEntity.kt` | `CategoryEntity.kt` | category entity |
| `TaskDao.kt` | `MealDao.kt` | CRUD + date range query + pending sync query |
| `TaskCategoryDao.kt` | `CategoryDao.kt` | category CRUD |
| `TaskRepository.kt` | MealRepository 逻辑 | API sync + Room CRUD + 乐观更新 |
| `TaskManager.kt` | `MealManager.kt` | 状态管理 + 本地 rrule 展开 |
| `TasksPage.kt` | `ChoresPage.kt` | **直接抄现有 Chore UI** |
| `TaskForm.kt` | `ChoreForm.kt` | 添加/编辑表单，增加 byday 控件 |

**关键改进（相比现有 Chore Pad）：**
- Room DB 本地存储 -> 离线可用
- 本地 rrule 展开 -> 减少后端压力
- SyncStatus + 乐观更新 -> 更快的 UI 响应
- version 冲突检测 -> 多设备安全

---

## Flutter 端

### 将 Chore 模块改名为 Task

在当前 UI 升级分支上继续开发，先 commit 保存已有 changes，然后将 `chore` 模块整体改名为 `task` 并接入新后端。

旧版 Chore 功能仅保留 H5 Vue 版本（未升级 App 的用户通过 WebView 使用）。Flutter 端不再保留 chore 模块。

**改名 + 适配：**

| 原文件 | 改名为 | 改动 |
| --- | --- | --- |
| `lib/src/manager/chore.dart` | `lib/src/manager/task.dart` | Model 改用 repeat 对象，API 接 task 端点 |
| `lib/src/page/chore/chores.dart` | `lib/src/page/task/tasks.dart` | 列表页 |
| `lib/src/page/chore/chore_detail.dart` | `lib/src/page/task/task_detail.dart` | 详情页 |
| `lib/src/page/chore/chore_edit.dart` | `lib/src/page/task/task_edit.dart` | 编辑页 + byday 控件 |
| `lib/src/page/chore/chore_categories.dart` | `lib/src/page/task/task_categories.dart` | 分类管理 |
| `lib/src/page/chore/chore_category_edit.dart` | `lib/src/page/task/task_category_edit.dart` | 分类编辑 |

**Manager 改动（`manager/task.dart`）：**

- `ChoreDetail` -> `TaskDetail`，使用 `repeat` 对象（RepeatData: freq, interval, byday, bymonthday, bysetpos, until）
- 不再用 `repeatEvery` / `repeatType` 整数
- `completeds` 为日期字符串列表
- API 端点从 `chore/device/{deviceId}/...` 改为 `task/device/{deviceId}/...`
- **保留 RxList 状态管理模式**（`ChoreListManager` -> `TaskListManager`，Obx 响应式刷新、optimistic update 等逻辑不变）

**home.dart**：保留现有布局，仅将 chore 入口指向新的 task 页面。

---

## 向后兼容策略

```text
升级前:
  App (H5 Vue)   --chore API--> Django chore app ---> chore 表
  Pad             --chore API--> Django chore app ---> chore 表

升级后:
  App (H5 Vue)   --chore API--> Django chore app ---> chore 表 (不变，未升级用户)
  App (Flutter)   --task API-->  Django task app  ---> task 表  (新)
  Pad (新版)      --task API-->  Django task app  ---> task 表  (新)
```

- 未升级 App 用户通过 H5 Vue WebView 继续用 chore API，完全不受影响
- 新版 Flutter App 不再有 chore 模块，直接用 task
- 新版 Pad 同上
- 两套数据独立，不需要双写
- 唯一需要的是一次性数据迁移脚本（chore -> task）

---

## 实施顺序

```text
Phase 1: 新建 base app + 提取公共层
  |-- 1a. 创建 pronext/base/ app (models.py: ChangeType, BaseCategory, BaseRecurrableModel)
  |-- 1b. 移动 rrule_utils.py, recurrence_utils.py, RepeatSerializer 到 base
  +-- 1c. Meal app 改为继承 base（验证无新 migration）

Phase 2: Django Task App
  |-- 2a. 创建 task app (models, admin)
  |-- 2b. 编写 options.py (CRUD + THIS/ALL/AND_FUTURE)
  |-- 2c. 编写 viewset_app.py + viewset_pad.py
  |-- 2d. 注册路由
  +-- 2e. 编写单元测试

Phase 3: 数据迁移
  +-- 3a. 编写 migrate_chores_to_tasks management command

Phase 4: Flutter -- chore 改名 task（在当前 UI update 分支上，先 commit 已有 changes）
  |-- 4a. 将 manager/chore.dart 改名为 manager/task.dart，接 task API（保留 RxList 状态管理）
  |-- 4b. 将 page/chore/ 改名为 page/task/，类名/路由全部 rename
  |-- 4c. Model 改用 repeat 对象 + 增加 byday 选择控件
  +-- 4d. home.dart chore 入口指向 task 页面

Phase 5: Pad Task 模块（已建新分支，独立开发）
  |-- 5.1 Beat data class 添加 task/task_cate 字段 + Retrofit TaskApi 接口定义
  |-- 5.2 Room Entities (TaskEntity, TaskCategoryEntity) + DAOs + TaskDatabase
  |-- 5.3 TaskRepository (同步 + CRUD + 乐观更新 + 版本冲突 + DEVICE_MISMATCH)
  |-- 5.4 Models (data classes) + TaskManager (状态管理 + 本地 rrule 展开 + Signal)
  |-- 5.5 UI 页面 (从 Chore 复制 5 个文件并适配 TaskManager/ExpandedTask)
  |-- 5.6 导航注册 (Page.kt) + 设置页适配 (SettingPage.kt) + 日历预览
  +-- 5.7 集成测试 (离线/rrule一致性/乐观更新/版本冲突/Beat/Category)

Phase 6: 部署
  |-- 6a. 部署后端（旧 chore API 不受影响）
  |-- 6b. 夜间运行数据迁移脚本
  |-- 6c. 发布 Pad 更新（1小时内全量升级）
  +-- 6d. 发布 Flutter App 更新

Phase 7: 清理（远期）
  +-- 确认所有用户已升级后，下线 chore app
```

---

## 关键文件清单

### 后端 -- Base App（新建）

- `server/pronext/base/models.py` -- ChangeType, BaseCategory, BaseRecurrableModel
- `server/pronext/base/rrule_utils.py` -- rrule 工具函数（从 meal 移入）
- `server/pronext/base/recurrence_utils.py` -- rrule 展开函数（从 meal 移入）
- `server/pronext/base/serializers.py` -- RepeatSerializer（从 meal 移入）

### 后端 -- Meal（适配 base）

- `server/pronext/meal/models.py` -- 改继承 base 基类
- `server/pronext/meal/rrule_utils.py` -- 删除，import 改从 base
- `server/pronext/meal/recurrence.py` -- 删除，import 改从 base

### 后端 -- Task（新建）

- `server/pronext/task/models.py`
- `server/pronext/task/options.py`
- `server/pronext/task/viewset_app.py`
- `server/pronext/task/viewset_pad.py`
- `server/pronext/task/admin.py`
- `server/pronext/task/management/commands/migrate_chores_to_tasks.py`

### Pad（新建）

- `pad/.../modules/task/` -- TaskManager, TasksPage, TaskForm
- `pad/.../database/TaskDatabase.kt`
- `pad/.../database/entities/TaskEntity.kt`, `TaskCategoryEntity.kt`
- `pad/.../database/dao/TaskDao.kt`, `TaskCategoryDao.kt`

### Flutter（从 chore 改名）

- `mobile/lib/src/manager/task.dart` -- 原 chore.dart
- `mobile/lib/src/page/task/` -- 原 page/chore/，全部 rename 为 task_*

---

## 验证方案

1. **base app 提取验证**：`python3 manage.py makemigrations` 后确认 meal app 无新 migration（base app 本身也不应有 migration，因为全是 abstract model）
2. **Task 后端测试**：rrule_utils, recurrence, options 的单元测试（参考 meal/tests.py）
3. **数据迁移验证**：在测试数据上运行迁移脚本，验证 rrule 转换正确性
4. **旧 Chore API 回归**：确认 chore 端点行为不变
5. **Pad 本地展开**：验证 RRuleParser 对 task 的 rrule 展开结果与后端一致
6. **Flutter E2E**：完成 TEST_CHECKLIST.md 全部测试项（适配为 task 版本）
7. **离线测试**：Pad 断网后切换日期，验证 task 数据从 Room 加载

---

## Phase 5 详细计划：Pad Task Module

### 概述

在 Pad 的独立分支上，新建 Task 模块取代旧 Chore 模块。采用 Meal 模块的架构（Room DB + 本地 rrule 展开 + SyncStatus 乐观更新），UI 从现有 Chore 模块复制并适配。

### 前置条件

- [x] Django `pronext.task` API 已就绪（Pad viewset: `/pad-api/task/...`）
- [x] Beat flags `task` / `task_cate` 已添加到 Django Beat model
- [ ] Pad Beat data class 需要添加 `task` / `task_cate` 字段

### 目录结构（目标）

```text
pad/app/src/main/java/it/expendables/pronext/
├── database/
│   ├── TaskDatabase.kt                    # 新建：Room DB，2表
│   ├── entities/
│   │   ├── TaskEntity.kt                  # 新建：Task entity
│   │   ├── TaskCategoryEntity.kt          # 新建：TaskCategory entity
│   │   └── SyncStatus.kt                  # 已有：复用
│   ├── dao/
│   │   ├── TaskDao.kt                     # 新建
│   │   └── TaskCategoryDao.kt             # 新建
│   └── repository/
│       └── TaskRepository.kt              # 新建：同步+CRUD（参照 MealRepository）
│
├── modules/task/                           # 新建模块
│   ├── Models.kt                          # 数据类：Task, TaskCategory, TaskChangeType
│   ├── TaskManager.kt                     # 状态管理 + rrule 展开 + Signal 监听
│   ├── TasksPage.kt                       # 主页面（从 ChoresPage 复制适配）
│   ├── TaskForm.kt                        # 添加/编辑表单（从 ChoreForm 复制适配）
│   ├── TasksCard.kt                       # 分类卡片（从 ChoresCard 复制适配）
│   ├── TaskItem.kt                        # 单项组件（从 ChoreItem 复制适配）
│   └── TaskCategories.kt                  # 分类管理（从 ChoreCategories 复制适配）
│
└── modules/common/Managers.kt             # 修改：Beat 添加 task/task_cate 字段
```

### Step 5.1: Beat 字段 + API 接口定义

**文件：**

- `modules/common/Managers.kt` — Beat data class 添加 `task: Boolean = false`, `task_cate: Boolean = false`
- `database/repository/TaskRepository.kt` — 定义 Retrofit TaskApi 接口

**TaskApi 接口（参照 MealApi）：**

```kotlin
private interface TaskApi {
    @GET("task/category/list")
    suspend fun categoryList(): Res<TaskCategoryResponse>

    @GET("task/list")
    suspend fun taskList(
        @Query("start_date") startDate: String?,
        @Query("end_date") endDate: String?
    ): Res<TaskResponse>

    @GET("task/{id}/detail")
    suspend fun taskDetail(@Path("id") id: Long): Res<TaskResponse>

    @POST("task/add")
    suspend fun addTask(@Body body: TaskAddRequest): IdRes

    @PUT("task/{id}/update")
    suspend fun updateTask(@Path("id") id: Long, @Body body: TaskUpdateRequest)

    @POST("task/{id}/complete")
    suspend fun completeTask(@Path("id") id: Long, @Body body: CompleteRequest)

    @HTTP(method = "DELETE", path = "task/{id}/delete", hasBody = true)
    suspend fun deleteTask(@Path("id") id: Long, @Body body: TaskDeleteRequest)
}
```

### Step 5.2: Room Database — Entities + DAOs

**TaskCategoryEntity（参照 CategoryEntity）：**

```kotlin
@Entity(tableName = "task_categories")
data class TaskCategoryEntity(
    @PrimaryKey val id: Long,
    val name: String,
    val color: String,
    val hidden: Boolean = false,
    val updatedAt: String? = null,
    val lastSyncedAt: Long = System.currentTimeMillis()
)
```

**TaskEntity（参照 MealEntity，去掉 recipe 相关）：**

```kotlin
@Entity(
    tableName = "tasks",
    indices = [Index("dueDate"), Index("syncStatus"), Index("categoryId")]
)
data class TaskEntity(
    @PrimaryKey val id: Long,
    val categoryId: Long,
    val content: String,
    val dueDate: String,               // yyyy-MM-dd
    val dueTime: String? = null,       // HH:mm:ss or null (all-day)
    val hasRepeat: Boolean = false,
    val repeatFlag: String? = null,
    val rrule: String? = null,
    val exdates: String? = null,       // comma-separated dates
    val completeds: String? = null,    // comma-separated dates
    val version: Int = 1,
    val updatedAt: String? = null,
    val syncStatus: SyncStatus = SyncStatus.SYNCED,
    val lastSyncedAt: Long = System.currentTimeMillis()
) {
    companion object {
        fun generateLocalId(): Long = -System.currentTimeMillis()
    }
}
```

**TaskDao（参照 MealDao，无 Recipe JOIN）：**

- `getTasksForDateRange(startDate, endDate): Flow<List<TaskEntity>>` — 含 rrule 任务
- `getTasksForDateRangeOnce(startDate, endDate): List<TaskEntity>`
- `getTaskById(id): TaskEntity?`
- `getPendingTasks(): List<TaskEntity>` — syncStatus != SYNCED
- `insert(task)`, `insertAll(tasks)`, `update(task)`, `deleteById(id)`, `deleteAll()`
- `updateSyncStatus(id, status)`

**TaskCategoryDao（参照 CategoryDao）：**

- `getAll(): Flow<List<TaskCategoryEntity>>`
- `getAllOnce(): List<TaskCategoryEntity>`
- `insertAll(categories: List<TaskCategoryEntity>)`
- `deleteAll()`

**TaskDatabase（独立 Room DB，参照 MealDatabase）：**

```kotlin
@Database(
    entities = [TaskCategoryEntity::class, TaskEntity::class],
    version = 1,
    exportSchema = false
)
abstract class TaskDatabase : RoomDatabase() {
    abstract fun taskCategoryDao(): TaskCategoryDao
    abstract fun taskDao(): TaskDao

    companion object {
        private const val DATABASE_NAME = "task_database"
        // getInstance(), destroyInstance() — 同 MealDatabase 单例模式
    }
}
```

**独立 DB 的决策理由：** 不碰已稳定的 MealDatabase (v5)，独立版本管理，migration 失败互不影响。未来如果模块更多可以考虑统一。

### Step 5.3: TaskRepository — 同步 + CRUD

**参照 MealRepository (~500行)，核心逻辑：**

1. `performInitialSync()` — 顺序同步 categories → tasks
2. `syncCategoriesFromServer()` — GET category/list → 全量替换本地
3. `syncTasksFromServer(startDate?, endDate?)` — GET task/list → upsert 本地（保留 PENDING 状态的记录）
4. `addTask(request)` → 本地创建(PENDING_CREATE, 负数ID) → POST /task/add → 更新本地ID(SYNCED)
5. `updateTask(id, request, changeType?, repeatFlag?)` → 本地更新(PENDING_UPDATE) → PUT → SYNCED
   - THIS/AND_FUTURE 操作后需要 re-sync 当前日期范围（服务端会创建新记录）
6. `deleteTask(id, changeType?, repeatFlag?)` → 本地标记(PENDING_DELETE) → DELETE → 本地删除
7. `completeTask(id, completed, repeatFlag)` → 本地更新 completeds → POST /task/{id}/complete
8. `syncPendingChanges()` — 遍历所有 PENDING 记录，重试
9. `destroyDatabase()` — 清空数据 + fire Signal

**错误处理（复用 MealRepository 模式）：**

- 409 (Version Conflict) → Hud 提示 + re-sync from server
- 403 + DEVICE_MISMATCH → destroyDatabase() → fire Signal

### Step 5.4: Models + TaskManager — 状态管理

**Models.kt（Serializable data classes for API）：**

```kotlin
@Serializable data class TaskCategoryResponse(val id: Long, val name: String, val color: String, val hidden: Boolean)
@Serializable data class TaskResponse(
    val id: Long, val content: String, val category_id: Long,
    val due_date: String, val due_time: String?,
    val rrule: String?, val exdates: List<String>?,
    val completeds: List<String>?, val has_repeat: Boolean,
    val repeat_flag: String?, val completed: Boolean, val version: Int
)
@Serializable data class TaskAddRequest(val category: Long, val content: String, val due_date: String, ...)
@Serializable data class TaskUpdateRequest(...)
@Serializable data class TaskDeleteRequest(val change_type: Int?, val repeat_flag: String?)
@Serializable data class CompleteRequest(val completed: Boolean, val repeat_flag: String?)
enum class TaskChangeType(val value: Int) { THIS(0), ALL(1), AND_FUTURE(2) }
```

**TaskManager.kt（参照 MealManager，~400行）：**

状态属性：

- `date: MutableState<String>` — 当前查看日期
- `categories: MutableState<List<TaskCategoryEntity>>` — 从 Room Flow 观察
- `tasks: MutableState<List<ExpandedTask>>` — rrule 展开后的任务列表
- `hideCompleted / hideExpired: MutableState<Boolean>` — 过滤
- `isLoading: MutableState<Boolean>`

**ExpandedTask** — 展开后的单次任务实例：

```kotlin
data class ExpandedTask(
    val entity: TaskEntity,
    val category: TaskCategoryEntity?,
    val occurrenceDate: String,       // 当前实例的日期
    val isCompleted: Boolean,         // completeds 包含 occurrenceDate
)
```

核心方法：

1. `initialize()` — 启动 Room Flow 观察 + Signal 监听
2. `expandTasks(entities, categories, date)` → `RRuleParser.getOccurrencesAsStrings()` 本地展开 → 过滤当天 → 构建 ExpandedTask
3. `paging(direction)` — 日期翻页
4. `toggleComplete(task)` — 乐观更新 + repository.completeTask()

Signal 监听：

```kotlin
Signal.add(Signal.Key.HeartBeat) { userInfo ->
    syncPendingChangesIfNeeded()
    val beat = userInfo["beat"] as? Beat
    if (beat?.task == true) repository.syncTasksFromServer(...)
    if (beat?.task_cate == true) repository.syncCategoriesFromServer()
}
Signal.add(Signal.Key.AuthDidLogin) { initialize() }
Signal.add(Signal.Key.AuthDidLogout) { deInitialize() }
Signal.add(Signal.Key.DayChanged) { refreshDate() }
```

### Step 5.5: UI 页面（从 Chore 复制适配）

| 源文件 | 目标文件 | 关键改动 |
| --- | --- | --- |
| `chore/ChoresPage.kt` | `task/TasksPage.kt` | @MainDestination, ChoreManager→TaskManager, Signal keys |
| `chore/ChoreForm.kt` | `task/TaskForm.kt` | 接 TaskRepository, 用 repeat 对象, `hasByDay = true` |
| `chore/ChoresCard.kt` | `task/TasksCard.kt` | 适配 ExpandedTask, category 从 Room |
| `chore/ChoreItem.kt` | `task/TaskItem.kt` | completed 用 occurrenceDate 判断, 乐观更新 |
| `chore/ChoreCategories.kt` | `task/TaskCategories.kt` | API 路径改 task/category/... |

TaskForm 关键改动：

- `repeat` 使用 `RepeatCard`（已有共享组件，设 `hasByDay = true`）
- 编辑重复任务时展示 `ChangeConfirm` 对话框（已有共享组件）
- `category_ids` 多选改为 `categoryId` 单选

### Step 5.6: 导航注册 + 设置页适配

修改文件：

- `common/Page.kt` — `ChoresPageDestination` → `TasksPageDestination`，label "Chores" → "Tasks"
- `modules/settings/SettingPage.kt` — TabItem "Chores" → "Tasks"，`ChoresCard()` → `TasksCard()`
- `modules/calendar/CalendarPage.kt` — Chore 预览改为 Task 预览

### Step 5.7: 集成测试

1. **离线测试**：断网后切换日期，验证 tasks 从 Room 加载
2. **rrule 展开一致性**：对比 Pad 本地展开与后端返回
3. **乐观更新**：完成/取消完成任务，UI 立即响应
4. **版本冲突**：模拟多设备修改，验证 409 处理
5. **重复任务操作**：THIS/ALL/AND_FUTURE 的增删改
6. **Beat 信号**：Django admin 修改 task 数据，验证 Pad 自动同步
7. **Category 管理**：增删改分类，Room + UI 同步

### 依赖关系

```text
Step 5.1 (Beat + API) ──┐
                         ├── Step 5.2 (Entities + DAOs) ── Step 5.3 (Repository)
                         │                                        │
                         └── Step 5.4 (Models) ──────────────────┤
                                                                  │
                                    Step 5.5 (UI Pages) ─────────┤
                                                                  │
                                    Step 5.6 (Navigation) ───────┤
                                                                  │
                                    Step 5.7 (Testing) ──────────┘
```

### 预计工作量

| Step | 描述 | 复杂度 | 预估 |
| --- | --- | --- | --- |
| 5.1 | Beat + API 定义 | 低 | 0.5h |
| 5.2 | Entities + DAOs | 低 | 1h |
| 5.3 | TaskRepository | 高 | 3-4h |
| 5.4 | Models + TaskManager | 中 | 2-3h |
| 5.5 | UI 页面（从 Chore 复制） | 中 | 2-3h |
| 5.6 | 导航 + 设置 | 低 | 0.5h |
| 5.7 | 集成测试 | 中 | 1-2h |
| **总计** | | | **~10-14h** |

### 注意事项

1. **TaskDatabase 独立于 MealDatabase**：两个独立的 Room DB，互不影响
2. **SyncStatus 复用**：`database/entities/SyncStatus.kt` 已经是共享的
3. **RRuleParser 复用**：`utils/RRuleParser.kt` 已经是共享的，无需修改
4. **RepeatCard/ChangeConfirm 复用**：`components/` 下的共享组件
5. **Task 不需要 Recipe**：比 Meal 简单，没有 Recipe 表和 JOIN 查询
6. **category_ids → category FK**：旧 Chore 用 `category_ids: List<Long>` 多选，Task 改为单个 `categoryId: Long` FK
7. **completeds 格式**：逗号分隔的日期字符串存储在 Room（如 `"2025-01-15,2025-01-16"`），与后端 JSON 数组对应
