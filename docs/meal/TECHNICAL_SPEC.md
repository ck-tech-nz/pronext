# Meal 功能技术规格文档

> 最后更新: 2026-01-19
> 供未来 AI 开发者和维护者参考
>
> 本文档合并了原 `techical_spec.md` (Android 实现细节) 和 `TECHNICAL_SPEC.md` (全栈规格)，统一为完整的技术规格文档。

## 一、功能概述

Meal 模块是一个独立的餐饮计划功能，允许用户管理餐饮分类、食谱和每日餐饮安排。

**核心特性:**

- 分类管理（Breakfast, Lunch, Dinner, Snack）
- 食谱管理（支持卡路里记录）
- 餐饮计划（支持重复规则）
- 多设备同步（Beat 机制）
- 版本冲突检测

## 二、数据模型

### 2.1 模型关系图

```
Admin Templates (只读模板)
┌─────────────────────┐      ┌─────────────────────┐
│ DefaultCategory     │ 1:N  │ DefaultRecipe       │
│ - name              │─────▶│ - name              │
│ - color             │      │ - description       │
│ - order             │      │ - calorie           │
│ - is_active         │      │ - order             │
└─────────────────────┘      └─────────────────────┘
          │
          │ Signal: post_save(User)
          │ (新设备用户自动复制)
          ▼
User Data (用户数据)
┌─────────────────────┐      ┌─────────────────────┐
│ Category            │ 1:N  │ Recipe              │
│ - user (FK→User)    │─────▶│ - user (FK→User)    │
│ - name              │      │ - category (FK)     │
│ - color             │      │ - name              │
│ - order             │      │ - description       │
│ - is_hidden         │      │ - calorie           │
│ - version           │      │ - version           │
└─────────────────────┘      └─────────────────────┘
                                      │
                                      │ 1:N
                                      ▼
                             ┌─────────────────────┐
                             │ Meal                │
                             │ - user (FK→User)    │
                             │ - recipe (FK)       │
                             │ - plan_date         │
                             │ - note              │
                             │ - rrule             │
                             │ - exdates (JSON)    │
                             │ - version           │
                             └─────────────────────┘
```

### 2.2 模型字段详解

#### DefaultCategory / DefaultRecipe

- 管理员在 Django Admin 中配置
- 只影响新创建的设备用户
- `is_active=False` 的模板不会被复制

#### Category

```python
class Category(BaseCategory):
    user = ForeignKey(User, CASCADE, related_name='meal_categories')
    name = CharField(max_length=255)
    color = CharField(max_length=255, default="#000000")
    order = PositiveSmallIntegerField(default=0)
    is_hidden = BooleanField(default=False)  # 用户隐藏但不删除
    version = PositiveIntegerField(default=1)  # 并发控制

    class Meta:
        unique_together = ("user", "name")
```

#### Recipe

```python
class Recipe(Model):
    user = ForeignKey(User, CASCADE, related_name='meal_recipes')
    category = ForeignKey(Category, CASCADE, related_name='recipes')
    name = CharField(max_length=255)
    description = TextField(blank=True, null=True)
    calorie = PositiveIntegerField(null=True, blank=True)
    version = PositiveIntegerField(default=1)
```

#### Meal

```python
class Meal(Model):
    class ChangeType(IntegerChoices):
        THIS = 0, "this"
        ALL = 1, "all"
        AND_FUTURE = 2, "and future"

    user = ForeignKey(User, CASCADE, related_name='meals')
    recipe = ForeignKey(Recipe, CASCADE, related_name='meals')
    note = TextField(blank=True, null=True)
    plan_date = DateField()
    rrule = CharField(max_length=512, blank=True, null=True)  # RFC 5545 格式
    exdates = JSONField(default=list)  # ["2025-01-15", "2025-01-20"]
    version = PositiveSmallIntegerField(default=1)

    class Meta:
        indexes = [
            Index(fields=['user', 'plan_date']),
            Index(fields=['user', 'recipe']),
        ]
```

## 三、API 端点

### 3.1 Pad API (设备直连)

基础路径: `/pad-api/meal/`

| 方法   | 路径                           | 说明                  | 请求体                                                                       |
| ------ | ------------------------------ | --------------------- | ---------------------------------------------------------------------------- |
| GET    | `/category/list/`              | 获取分类列表          | -                                                                            |
| POST   | `/category/{id}/update/`       | 更新分类              | `{name?, color?, is_hidden?}`                                                |
| GET    | `/recipe/category/{id}/list/`  | 获取分类下食谱        | -                                                                            |
| POST   | `/recipe/add/`                 | 添加食谱              | `{category, name, description?, calorie?}`                                   |
| POST   | `/recipe/{id}/update/`         | 更新食谱              | `{name?, description?, calorie?}`                                            |
| DELETE | `/recipe/{id}/delete/`         | 删除食谱              | -                                                                            |
| GET    | `/list/?start_date=&end_date=` | 获取日期范围内的 Meal | Query: start_date, end_date                                                  |
| GET    | `/{id}/detail/`                | 获取 Meal 详情        | -                                                                            |
| POST   | `/add/`                        | 添加 Meal             | `{recipe, plan_date, note?, repeat?}`                                        |
| PUT    | `/{id}/update/`                | 更新 Meal             | `{recipe?, note?, plan_date?, repeat?, change_type?, repeat_flag?, version}` |
| DELETE | `/{id}/delete/`                | 删除 Meal             | `{change_type?, repeat_flag?}`                                               |

### 3.2 App API (跨设备管理)

基础路径: `/app-api/meal/device/{device_id}/`

端点与 Pad API 相同，多了 `device_id` 参数用于指定目标设备。

### 3.3 请求/响应示例

#### 添加重复 Meal

```json
// POST /pad-api/meal/add/
{
  "recipe": 5,
  "plan_date": "2025-01-15",
  "note": "Low carb today",
  "repeat": {
    "freq": "weekly",
    "interval": 1,
    "byday": ["MO", "WE", "FR"],
    "until": "2025-12-31"
  }
}
```

#### 更新单个实例 (THIS)

```json
// PUT /pad-api/meal/123/update/
{
  "recipe": 8,
  "change_type": 0,
  "repeat_flag": "2025-01-15",
  "version": 2
}
```

#### Meal 列表响应

```json
// GET /pad-api/meal/list/?start_date=2025-01-01&end_date=2025-01-31
[
  {
    "id": 123,
    "category_id": 1,
    "recipe_id": 5,
    "recipe": "Eggs",
    "calorie": 150,
    "plan_date": "2025-01-15",
    "rrule": "FREQ=WEEKLY;BYDAY=MO,WE,FR",
    "exdates": ["2025-01-20"],
    "has_repeat": true,
    "repeat_flag": "2025-01-15",
    "version": 2,
    "updated_at": "2025-01-10T08:30:00Z"
  }
]
```

> **注意**: `exdates` 字段是一个日期字符串数组，用于存储重复 Meal 中被删除的单个实例日期。客户端在展开 rrule 时需要过滤掉这些日期。

## 四、重复规则 (Recurrence)

### 4.1 RRULE 格式

使用 RFC 5545 iCalendar 标准:

```
FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;UNTIL=20251231
```

### 4.2 API repeat 对象

```python
{
    "freq": "daily" | "weekly" | "monthly" | "yearly",
    "interval": int,        # 间隔，默认 1
    "byday": ["MO", "TU", "WE", "TH", "FR", "SA", "SU"],  # 周几
    "bymonthday": int,      # 每月第几天 (1-31)
    "bysetpos": int,        # 第几个（用于"每月第二个周一"）
    "until": "YYYY-MM-DD"   # 结束日期
}
```

### 4.3 转换工具

```python
from pronext.meal.rrule_utils import repeat_to_rrule, rrule_to_repeat

# API → DB
rrule = repeat_to_rrule({"freq": "weekly", "byday": ["MO"]})
# => "FREQ=WEEKLY;BYDAY=MO"

# DB → API
repeat = rrule_to_repeat("FREQ=WEEKLY;BYDAY=MO")
# => {"freq": "weekly", "byday": ["MO"]}
```

### 4.4 获取重复实例

```python
from pronext.meal.recurrence import get_meal_occurrences

# 返回日期范围内的所有实例日期
dates = get_meal_occurrences(meal, start_date, end_date)
# => [date(2025, 1, 6), date(2025, 1, 13), ...]
```

### 4.5 UNTIL 格式标准化

`ical` 库要求 UNTIL 使用纯 DATE 格式 (YYYYMMDD)，不支持 datetime 格式。
`_normalize_rrule()` 自动处理格式转换：

```python
# recurrence.py
def _normalize_rrule(rrule: str) -> str:
    """
    Normalize rrule UNTIL value to DATE format (YYYYMMDD).
    Handles datetime formats like '20260131T00:00:00+08:00'.
    """
    # 输入: "FREQ=WEEKLY;UNTIL=20260131T00:00:00+08:00"
    # 输出: "FREQ=WEEKLY;UNTIL=20260131"
```

## 五、修改类型 (ChangeType)

重复 Meal 的更新/删除支持三种模式:

| 值  | 常量       | 行为     | 实现                                           |
| --- | ---------- | -------- | ---------------------------------------------- |
| 0   | THIS       | 仅此实例 | 原 Meal 添加 exdate，创建新非重复 Meal         |
| 1   | ALL        | 所有实例 | 直接更新/删除原 Meal                           |
| 2   | AND_FUTURE | 此及未来 | 原 Meal 设置 until，创建新 Meal 从指定日期开始 |

**关键参数:**

- `change_type`: 修改类型 (0/1/2)
- `repeat_flag`: 指定操作的日期 (YYYY-MM-DD)

### 5.1 客户端菜单显示规则 (Vue H5 & Pad)

客户端使用菜单组件显示操作选项。Vue H5 使用 `ChangeTypeSheet`，Pad 使用 `showChangeConfirm`。菜单项根据以下条件动态渲染：

#### 判断条件

| 条件 | 含义 | 判断逻辑 |
| --- | --- | --- |
| `immediately` | 非重复 meal | `!oHasRepeat` (原始 meal 无重复规则) |
| `isOriginalEvent` | 重复 meal 的第一个实例 | `repeat_flag == plan_date` 或无 `repeat_flag` |
| `hideThisOnly` | 重复设置已修改 | 当前 repeat 与原始 repeat 不同 (仅 Save 使用) |

#### Repeat item 更新/删除菜单选项显示优先级 (从高到低)

```
1. immediately=true     → 立即执行，不显示菜单
2. isOriginalEvent=true → 显示 "This..." 和 "All..."
3. hideThisOnly=true    → 显示 "This and Future..." 和 "All..."
4. 默认                  → 显示全部 3 个选项
```

#### 完整规则表

| 场景 | Save 菜单 | Delete 菜单 | 原因 |
| --- | --- | --- | --- |
| 非重复 meal | 立即执行 | 立即执行 | 无需选择 |
| 重复 meal - **第一个实例** | "This..." / "All..." | "This..." / "All..." | "This and Future..." = "All..." |
| 重复 meal - repeat 设置已改 | "This and Future..." / "All..." | 3 个全部 | "This only" 无法只改一个的重复规则 |
| 重复 meal - 其他情况 | 3 个全部 | 3 个全部 | 用户可选任意操作 |

#### 实现代码

请查看最新的 `h5/src/pages/meal/MealEdit.vue` 和 `pad/app/src/main/java/it/expendables/pronext/modules/meal/MealForm.kt`。

## 六、Beat 同步机制

### 6.1 触发同步

```python
from pronext.common.models import Beat

beat = Beat(device_id, rel_user_id)

# 分类变更
beat.should_refresh_meal_cate(True)

# Meal/Recipe 变更
beat.should_refresh_meal(True)

# Recipe 变更 (新增)
beat.should_refresh_meal_recipe(True)
```

### 6.2 心跳响应

设备每 5 秒发送心跳，响应包含:

```json
{
  "data": {
    "meal_cate": true, // 分类有更新
    "meal": false, // Meal 无更新
    "meal_recipe": true // Recipe 有更新
  }
}
```

### 6.3 Redis 存储

```
Key: :1:beat1:{device_id}
TTL: 15 秒
Value: {"meal_cate": true, "meal": false, ...}
```

## 七、版本冲突检测

### 7.1 工作原理

1. 客户端读取数据时获取 `version`
2. 更新时发送当前 `version`
3. 服务端检查版本是否匹配
4. 不匹配则返回冲突错误

### 7.2 冲突响应

```json
{
  "code": -5,
  "error": "version_conflict",
  "server_version": 3,
  "data": {
    "id": 123,
    "recipe": "Eggs"
    // ... 服务端最新数据
  }
}
```

### 7.3 处理建议

客户端收到冲突时应:

1. 展示服务端最新数据
2. 询问用户是否覆盖
3. 使用新 version 重新提交

## 八、懒加载初始化 (Lazy Initialization)

### 8.1 触发条件

当用户首次访问分类列表 API 时，自动初始化默认数据：

```python
# pronext/meal/viewset_base.py (CategoryViewSetMixin._list)
# pronext/meal/viewset_app.py (CategoryViewSet._list)

from .options import ensure_default_meal_data

def _list(self, request):
    device_id = self.get_device_id(request)
    # Lazy initialization - transparent to client
    ensure_default_meal_data(device_id)
    # ... return categories
```

### 8.2 初始化逻辑

```python
# pronext/meal/options.py
def ensure_default_meal_data(device_id: int) -> bool:
    """
    Ensures device user has default meal categories and recipes.
    Thread-safe with SELECT FOR UPDATE lock.
    """
    with transaction.atomic():
        user = User.objects.select_for_update().get(id=device_id)
        if Category.objects.filter(user=user).exists():
            return False  # Already initialized
        # Create categories and recipes from templates...
```

**特点:**

- **幂等性**: 多次调用不会重复创建
- **线程安全**: 使用 `select_for_update()` 防止并发初始化
- **透明**: 客户端无需额外操作，首次访问自动初始化

### 8.3 创建内容

- 4 个分类: Breakfast, Lunch, Dinner, Snack
- 34 个食谱: 分布在各分类

### 8.4 默认数据来源

从 `DefaultCategory` 和 `DefaultRecipe` 模板复制，可在 Django Admin 中管理。
只复制 `is_active=True` 的模板。

## 九、关键文件索引

```
pronext/meal/
├── models.py           # 数据模型 (5 个)
├── options.py          # 核心业务逻辑
│   ├── ensure_default_meal_data()  # 懒加载初始化默认数据
│   ├── add_meal()      # 添加 Meal
│   ├── update_meal()   # 更新 Meal (含 ChangeType 处理)
│   ├── delete_meal()   # 删除 Meal (含 ChangeType 处理)
│   └── get_meals()     # 获取日期范围内的 Meal (展开重复)
├── serializers.py      # API 序列化器
├── viewset_pad.py      # Pad API 路由入口
├── viewset_app.py      # App API 路由 (跨设备)
├── viewset_base.py     # ViewSet 基类和 Mixin
├── recurrence.py       # 重复规则计算
│   ├── _normalize_rrule()       # 标准化 UNTIL 为 DATE 格式
│   └── get_meal_occurrences()   # 获取日期范围内的重复实例
├── rrule_utils.py      # RRULE ↔ repeat 转换
├── admin.py            # Django Admin 配置
└── tests.py            # 测试用例
```

## 十、常见问题排查

### 10.1 Beat 不同步

**症状**: 更新后设备未收到同步通知

**检查**:

1. Redis 连接: `redis-cli -n 8 KEYS :1:beat*`
2. 确认 Beat 调用: 检查 `options.py` 中是否调用了 `should_refresh_meal()`
3. TTL: Beat 有 15 秒 TTL，确保在此期间心跳

### 10.2 版本冲突频繁

**症状**: 用户频繁看到冲突提示

**原因**: 多设备同时编辑，或客户端缓存了旧版本

**解决**: 确保每次编辑前先获取最新数据

### 10.3 重复 Meal 展开异常

**症状**: 日期范围内缺少或多出实例

**检查**:

1. `rrule` 格式是否正确
2. `exdates` 是否包含了该日期
3. `UNTIL` 日期是否早于查询范围

**UNTIL 格式错误**:

如果出现 `ValueError: Expected value to match DATE pattern`，说明 UNTIL 包含时间/时区信息。
`_normalize_rrule()` 会自动处理，但如需手动修复数据库：

```sql
-- 查找问题数据
SELECT id, rrule FROM meal_meal WHERE rrule LIKE '%UNTIL=%T%';
```

### 10.4 默认数据未创建

**症状**: 用户没有分类和食谱

**检查**:

1. 用户是否访问过分类列表 API (懒加载触发点)
2. `DefaultCategory.is_active` 是否为 True
3. `DefaultRecipe.is_active` 是否为 True
4. 检查 `ensure_default_meal_data()` 是否被正确调用

## 十一、扩展指南

### 11.1 添加新的 Beat flag

1. 在 `pronext/common/models.py` 添加字段和方法
2. 在业务逻辑中调用新方法
3. 如有 Go Heartbeat 服务，同步更新

### 11.2 添加新 API 端点

1. 在 `viewset_base.py` 添加 Mixin
2. 在 `viewset_pad.py` 和 `viewset_app.py` 注册路由
3. 添加对应的序列化器
4. 编写测试用例

### 11.3 修改重复规则支持

1. 更新 `rrule_utils.py` 中的转换逻辑
2. 更新 `recurrence.py` 中的展开逻辑
3. 更新 `RepeatSerializer` 验证

---

## 十二、Android 客户端 (pad)

### 12.1 架构概述

Meal 模块提供餐饮计划功能，采用 **Local-First** 架构，使用 Room 数据库进行本地持久化，并与后端 API 同步。

#### 核心组件

| 组件             | 文件                                                    | 职责                        |
| ---------------- | ------------------------------------------------------- | --------------------------- |
| `MealManager`    | `MealManager.kt`                                        | 状态管理、UI 协调、同步编排 |
| `MealRepository` | `MealRepository.kt`                                     | 数据层、Room 操作、API 调用 |
| `MealDatabase`   | `MealDatabase.kt`                                       | Room 数据库配置             |
| DAOs             | `CategoryDao.kt`, `RecipeDao.kt`, `MealDao.kt`          | 数据库操作                  |
| Entities         | `CategoryEntity.kt`, `RecipeEntity.kt`, `MealEntity.kt` | 数据模型                    |

#### 数据流

```
UI <-> MealManager <-> MealRepository <-> Room Database
                              |
                              v
                         Backend API
```

### 12.2 数据库架构

Meal 使用**独立的 Room 数据库**，与其他功能完全隔离：

```
pad 数据存储
├── meal_database (Room, 独立文件)
│   ├── categories 表
│   ├── recipes 表
│   └── meals 表
│
└── 其他功能 (Calendar/Chore/Photo)
    └── 纯服务器同步，无本地数据库
```

**数据库配置** (`MealDatabase.kt`):

```kotlin
@Database(
    entities = [CategoryEntity::class, RecipeEntity::class, MealEntity::class],
    version = 3,
    exportSchema = false
)
abstract class MealDatabase : RoomDatabase() {
    companion object {
        fun getInstance(context: Context): MealDatabase {
            return Room.databaseBuilder(...)
                .fallbackToDestructiveMigration()  // 版本不匹配时清空数据
                .build()
        }
    }
}
```

### 12.3 本地数据模型

**CategoryEntity**

```kotlin
@Entity(tableName = "categories")
data class CategoryEntity(
    @PrimaryKey val id: Long,
    val name: String,
    val color: String,
    val order: Int,
    val isHidden: Boolean,
    val updatedAt: String?,
    val lastSyncedAt: Long
)
```

**RecipeEntity**

```kotlin
@Entity(tableName = "recipes")
data class RecipeEntity(
    @PrimaryKey val id: Long,
    val categoryId: Long,
    val name: String,
    val description: String?,
    val calorie: Int?,
    val version: Int,
    val syncStatus: SyncStatus,  // SYNCED, PENDING_CREATE, PENDING_UPDATE, PENDING_DELETE
    val lastSyncedAt: Long
)
```

**MealEntity**

```kotlin
@Entity(tableName = "meals")
data class MealEntity(
    @PrimaryKey val id: Long,  // 负值表示本地创建，待同步
    val recipeId: Long,
    val categoryId: Long,
    val planDate: String,      // "yyyy-MM-dd" 格式
    val note: String?,
    val calorie: Int?,
    val hasRepeat: Boolean,
    val repeatFlag: String?,
    val rrule: String?,
    val exdates: String?,      // 逗号分隔的排除日期，如 "2026-01-15,2026-01-20"
    val version: Int,
    val syncStatus: SyncStatus,
    val lastSyncedAt: Long
)
```

### 12.4 初始化流程

新用户登录/用户reset 设备重新激活

1. [阻塞] 同步 Categories & Recipes 到 Room
2. 渲染页面（显示 Categories）
3. [后台] 异步同步 Meals 到 Room
4. 更新 UI（显示 Meals）

非首次使用时：直接渲染，无需阻塞。


```
MainActivity.onCreate()
    |
    v
MealManager.initialize(context)
    |
    +-- Create MealRepository
    +-- Start observing local data (Flow)
    +-- Check AuthManager.isAuth
           |
           +-- true: performInitialSync()
           +-- false: Wait for AuthDidLogin signal
```

#### Signal 处理器

| Signal                  | 动作                     |
| ----------------------- | ------------------------ |
| `AuthDidLogin`          | 从服务器开始初始同步     |
| `AuthDidLogout`         | 销毁数据库，清除状态     |
| `MealDatabaseDestroyed` | 重新初始化并同步         |
| `HeartBeat`             | 重试待同步数据，刷新数据 |

### 12.5 同步机制

#### 与 Calendar/Event/Chores 的关键区别

Meal 模块的同步方式与 Calendar/Event **完全不同**：

| 特性 | Meal 模块 | Calendar/Event 模块 |
|------|-----------|---------------------|
| **本地存储** | Room 数据库持久化 | 无本地数据库，纯 API 请求 |
| **重复规则存储** | 原始 `rrule` 字符串存入 Room | 不存储，每次从服务器获取 |
| **重复事件展开** | **客户端本地解析** (RRuleParser) | **服务端预展开** |
| **API 返回格式** | 原始数据 (含 rrule) | 展开后的多个独立对象 |
| **离线支持** | ✅ 支持离线浏览和操作 | ❌ 需要网络连接 |
| **数据缓存** | 周级别缓存，导航无需 API | 无缓存，每次查询调用 API |

**为什么 Meal 采用不同架构？**

1. **本地优先体验**：用户切换周时无需等待网络，直接查询 Room
2. **离线支持**：支持离线查看和创建 Meal，网络恢复后同步
3. **性能优化**：重复规则本地展开避免服务端重复计算
4. **数据完整性**：本地存储原始 rrule，保证数据不丢失

#### 重复规则本地解析

**存储格式** (`MealEntity.rrule`):
```
FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR;UNTIL=20260131
```

**解析工具** (`RRuleParser.kt`，使用 [dmfs/lib-recur](https://github.com/dmfs/lib-recur) 库):

```kotlin
// 获取指定日期范围内的所有重复实例（自动过滤 exdates）
fun getOccurrencesAsStrings(
    startDateStr: String,      // 原始 planDate (基准日期)
    rruleString: String?,      // rrule 字符串
    rangeStartStr: String,     // 查询范围起始
    rangeEndStr: String,       // 查询范围结束
    exdates: List<String>? = null,  // 要排除的日期列表
    maxOccurrences: Int = 365  // 安全限制
): List<String>
```

**展开流程** (MealManager):

```
查询 Room 获取原始 MealEntity 列表
    ↓
遍历每个 MealEntity:
    ├── 如果 rrule == null → 直接使用 planDate
    └── 如果 rrule != null → RRuleParser.getOccurrencesAsStrings()
                              传入 exdates 参数过滤被删除的实例
                              返回该周内所有有效实例日期
    ↓
按日期分组，构建 MealPlan 展示给用户
```

**示例**：一个每周一三五重复的 Meal（周三被删除）：

```
Room 存储:
  id=123, planDate="2026-01-06", rrule="FREQ=WEEKLY;BYDAY=MO,WE,FR", exdates="2026-01-22"

查询 2026-01-20 ~ 2026-01-26 这一周:
  RRuleParser 展开后返回: ["2026-01-20", "2026-01-24"]  // 2026-01-22 被 exdates 过滤

UI 展示:
  周一(20日): Meal#123
  周三(22日): (空，已被删除)
  周五(24日): Meal#123
```

#### Sync Status

每个实体都有 `syncStatus` 字段:

- `SYNCED` - 数据与服务器匹配
- `PENDING_CREATE` - 仅本地，需要在服务器上创建
- `PENDING_UPDATE` - 本地修改，需要服务器更新
- `PENDING_DELETE` - 标记为删除

#### Local-First 架构

1. 写操作立即存入 Room 数据库
2. 后台同步到服务器
3. 同步状态通过 `syncStatus` 跟踪
4. Beat 心跳触发增量同步

#### 写操作同步策略

根据操作复杂度采用不同的同步策略：

| 操作类型 | changeType | 本地更新 | 服务器同步后 | UI 刷新 |
|---------|-----------|---------|------------|--------|
| **简单操作** | 无 / ALL(1) | ✅ 立即更新 Room (含 rrule) | 更新 syncStatus | 即时 (Room Flow) |
| **复杂操作** | THIS(0) / AND_FUTURE(2) | ❌ 仅标记状态 | 同步当前周数据 | 服务器返回后一次性刷新 |

**为什么区分？**

- **简单操作**：本地可完整模拟服务器行为，rrule 由 `RRuleParser.generateRrule()` 本地生成
- **复杂操作**：服务器会创建/修改多条记录（如拆分重复 meal），本地无法模拟

**复杂操作的服务器行为：**

| changeType | 服务器行为 |
|-----------|-----------|
| THIS(0) 更新 | 原 meal 添加 exdate，创建新的非重复 meal |
| THIS(0) 删除 | 原 meal 添加 exdate |
| AND_FUTURE(2) 更新 | 原 meal 添加 UNTIL 截断，创建新 meal 从指定日期开始 |
| AND_FUTURE(2) 删除 | 原 meal 添加 UNTIL 截断 |

**流程图：**

```
简单操作 (ALL / 无 changeType):
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ 用户保存    │───▶│ 本地更新 Room│───▶│ UI 立即刷新 │
│             │    │ (含 rrule)   │    │ (Room Flow) │
└─────────────┘    └──────┬──────┘    └─────────────┘
                          │
                          ▼ 后台
                   ┌─────────────┐
                   │ 同步到服务器 │
                   └─────────────┘

复杂操作 (THIS / AND_FUTURE):
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ 用户保存    │───▶│ 同步到服务器 │───▶│ 拉取当前周  │───▶│ UI 一次刷新 │
│             │    │ (等待响应)   │    │ 最新数据    │    │ (Room Flow) │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

#### 初始同步

顺序同步以确保数据依赖:

```kotlin
suspend fun performInitialSync(startDate: String, endDate: String) {
    syncCategoriesFromServer()    // 步骤 1: 分类优先
    syncAllRecipesFromServer()    // 步骤 2: 食谱（依赖分类）
    syncMealsFromServer(...)      // 步骤 3: Meals（依赖食谱的 JOIN）
}
```

#### 增量同步

```
初始同步 (顺序执行):
1. GET /meal/category/list → 更新 categories 表
2. GET /meal/recipe/category/{id}/list → 更新 recipes 表
3. GET /meal/list?start_date=&end_date= → 更新 meals 表

增量同步 (Beat 触发):
- meal_cate=true → 同步分类
- meal_recipe=true → 同步食谱
- meal=true → 同步 Meal
```

#### Pending Changes Sync

每次 `HeartBeat` 时，重试同步待处理的本地更改:

```kotlin
suspend fun syncPendingChanges() {
    // 同步待处理的食谱 (PENDING_CREATE, PENDING_DELETE)
    // 同步待处理的 Meals (PENDING_CREATE, PENDING_DELETE)
    // 处理错误，删除无效条目以防止无限重试
}
```

#### 错误处理

| 错误                  | 动作                     |
| --------------------- | ------------------------ |
| 403 + DEVICE_MISMATCH | 销毁数据库，重新同步     |
| 4xx (其他)            | 删除无效的本地条目       |
| 5xx                   | 记录错误，下次心跳时重试 |
| 网络错误              | 记录错误，下次心跳时重试 |

### 12.6 设备不匹配处理

当设备重置并使用不同用户重新激活时，本地数据可能属于之前的设备所有者。后端返回 `403` 和 `DEVICE_MISMATCH` 错误代码。

#### 检测

```kotlin
private fun isDeviceMismatchError(e: HttpException): Boolean {
    if (e.code() != 403) return false
    val errorBody = e.response()?.errorBody()?.string() ?: ""
    return errorBody.contains("DEVICE_MISMATCH")
}
```

#### 后端响应格式

```json
{
  "error_code": "DEVICE_MISMATCH",
  "message": "Recipe not found or does not belong to this device"
}
```

#### 恢复流程

```
API 返回 403 + DEVICE_MISMATCH
    |
    v
MealRepository.destroyDatabase(context)
    |
    +-- 关闭数据库连接
    +-- 删除数据库文件
    +-- 重置 repository 实例
    +-- 触发 MealDatabaseDestroyed signal
    |
    v
MealManager 接收 signal
    |
    +-- 显示 "Syncing data..." 消息
    +-- 重新创建数据库
    +-- 从服务器同步
    +-- 显示 "Data synced" 消息
```

### 12.7 数据库销毁

#### 触发时机

1. **用户登出/设备重置** - `AuthDidLogout` signal
2. **检测到设备不匹配** - API 返回 403 + DEVICE_MISMATCH

#### 实现

```kotlin
// MealDatabase.kt
fun destroyInstance(context: Context) {
    synchronized(this) {
        INSTANCE?.close()
        INSTANCE = null
        context.applicationContext.deleteDatabase(DATABASE_NAME)
    }
}

// MealRepository.kt
fun destroyDatabase(context: Context) {
    synchronized(this) {
        INSTANCE = null
        MealDatabase.destroyInstance(context)
    }
    Signal.fire(Signal.Key.MealDatabaseDestroyed)
}
```

### 12.8 用户体验

#### 加载状态

| 状态                       | UI 指示器              |
| -------------------------- | ---------------------- |
| `isSyncingDatabase = true` | "Syncing data..." 消息 |
| `isLoadingRecipes = true`  | 食谱列表加载中         |
| 同步完成                   | "Data synced" 成功消息 |

#### 预计同步时间

| 操作       | 时长       |
| ---------- | ---------- |
| 删除数据库 | ~10ms      |
| 创建数据库 | ~50ms      |
| 同步分类   | ~200-500ms |
| 同步食谱   | ~500ms-2s  |
| 同步 Meals | ~200-500ms |
| **总计**   | **1-3 秒** |


### 12.10 关键文件索引

```
pad/app/src/main/java/it/expendables/pronext/
├── database/
│   ├── MealDatabase.kt           # Room 数据库定义
│   ├── dao/
│   │   ├── CategoryDao.kt        # 分类 DAO
│   │   ├── RecipeDao.kt          # 食谱 DAO
│   │   └── MealDao.kt            # Meal DAO
│   ├── entities/
│   │   ├── CategoryEntity.kt     # 分类实体
│   │   ├── RecipeEntity.kt       # 食谱实体
│   │   └── MealEntity.kt         # Meal 实体
│   └── repository/
│       └── MealRepository.kt     # 数据仓库 (API + DB)
│
├── modules/meal/
│   ├── MealPage.kt               # 主界面 (30KB)
│   ├── MealManager.kt            # 状态管理 (26KB)
│   ├── MealForm.kt               # 添加/编辑表单 (21KB)
│   └── RecipeForm.kt             # 食谱表单 (7KB)
│
└── common/
    └── Page.kt                   # SN 白名单定义 (Line 63)
```

---

## 十三、风险控制与回滚方案

### 13.1 回滚场景分析

#### 场景 1: 重装相同版本 APK

| 问题             | 答案                                                              |
| ---------------- | ----------------------------------------------------------------- |
| 数据库会重建吗？ | 不会，Room 数据库保留在 `/data/data/包名/databases/meal_database` |
| 会重新同步吗？   | 取决于 `lastSyncedAt`，通常会检查并增量同步                       |
| 数据残留？       | 无问题，数据完整保留                                              |

#### 场景 2: 降级到旧版本 APK (无 meal 功能)

| 问题             | 答案                             | 风险                                |
| ---------------- | -------------------------------- | ----------------------------------- |
| 数据库会重建吗？ | 不会，旧版本不访问 meal_database | 旧代码根本不知道 meal_database 存在 |
| 数据残留？       | **会有残留**，但无害             | meal_database 文件保留但不被使用    |
| 影响使用？       | **不影响**                       | Calendar/Chore/Photo 正常           |

#### 场景 3: 降级后再升级回新版本

```
v1.8.1 (有meal) → v1.8.0 (无meal) → v1.8.1 (有meal)
```

| 阶段               | 发生什么                                                          |
| ------------------ | ----------------------------------------------------------------- |
| 降级到 v1.8.0      | meal_database 文件保留，但不被访问                                |
| 升级回 v1.8.1      | Room 打开 meal_database，检查版本                                 |
| **如果版本匹配**   | 数据完整恢复                                                      |
| **如果版本不匹配** | `fallbackToDestructiveMigration()` 清空所有数据，重新从服务器同步 |

### 13.2 数据丢失风险

| 数据状态                | 降级后升级结果                 |
| ----------------------- | ------------------------------ |
| SYNCED (已同步)         | 从服务器恢复                   |
| PENDING_CREATE (待创建) | **永久丢失**                   |
| PENDING_UPDATE (待更新) | 本地修改丢失，但服务器有旧版本 |
| PENDING_DELETE (待删除) | 服务器数据会恢复               |

### 13.3 回滚方案

#### 方案 A: 安全回滚 (推荐)

```
如果发现问题需要回滚：
1. 发布旧版本 APK (无 meal 功能)
2. 用户自动更新/下载安装
3. Meal 入口消失（旧版本无 SN 白名单检查）
4. meal_database 文件残留但无害
5. 其他功能正常使用
6. 服务端 meal API 保留，不影响
```

**用户体验**:

- Calendar/Chore/Photo 完全不受影响
- Meal 功能"消失"，但数据仍在服务器
- 再次升级时，数据从服务器恢复

#### 方案 B: 服务端紧急关闭

```python
# 在 URL 配置中注释掉 meal 路由
# pronext_server/urls.py
# register_pad_route('meal', MealViewSet)  # 临时禁用

# 或在 viewset 中添加权限控制
class MealViewSet:
    def get_permissions(self):
        if settings.MEAL_FEATURE_DISABLED:
            raise PermissionDenied("Meal feature is temporarily disabled")
```

### 13.4 风险矩阵总结

| 风险项             | 对现有用户影响 | 可逆性               |
| ------------------ | -------------- | -------------------- |
| 服务端 meal 代码   | 无 (API 隔离)  | 可移除路由           |
| 服务端数据库迁移   | 无 (新表)      | 可保留不用           |
| 服务端 Beat flag   | 无 (additive)  | 忽略即可             |
| 客户端 meal UI     | 无 (SN 白名单) | 更新白名单或发旧版本 |
| 客户端 meal 数据库 | 无 (独立文件)  | 文件残留无害         |

### 13.5 发布检查清单

- [ ] 确认 SN 白名单只包含测试设备
- [ ] 确认服务端测试通过
- [ ] 确认数据库迁移可正常执行
- [ ] 准备旧版本 APK 作为回滚备份
- [ ] 监控白名单设备的错误日志

### 13.6 紧急联系

如发现严重问题：

1. 立即更新 SN 白名单为空列表 (禁用入口)
2. 发布旧版本 APK (如需彻底回滚)
3. 检查服务端错误日志
4. 评估是否需要清理服务端数据
