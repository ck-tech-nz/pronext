# Room 数据同步方案

> 适用于：**Meal 模块** 和 **Task 模块**（均使用 Room DB + 本地 rrule 架构）

## 问题描述

1. **Recipe version 未递增** — 通过 mobile H5 或 pad 更新 recipe 时，服务端不会递增 `Recipe.version`。Pad 的 `syncRecipesFromServer()` 使用 version 比对（`server.version > local.version`），导致更新被静默跳过。
2. **无法验证 Room 与 Server 数据一致性** — Room 数据在 Django Admin 中不可见。用户反馈"手机上有但 pad 上没有"时，没有诊断工具。
3. **Beat flag TTL 窗口问题** — Beat flag 在 15s 后过期。如果 pad 的 heartbeat 错过了这个窗口，数据变更将不可见，直到 app 重启。

## 现有架构

### Version 字段现状

| Entity           | Server has version?      | Server increments on update?            | Pad Room has version? | Pad uses version in sync?        |
| ---------------- | ------------------------ | --------------------------------------- | --------------------- | -------------------------------- |
| **Meal**         | Yes (BaseRecurrableModel)| Yes (`F('version') + 1` in options.py)  | Yes                   | No (full overwrite)              |
| **Recipe**       | Yes (`version` field)    | **NO — BUG**                            | Yes                   | Yes (skips if `server <= local`) |
| **MealCategory** | Yes (`version` field)    | Yes (on update/reorder)                 | **No**                | No                               |
| **Task**         | Yes (BaseRecurrableModel)| Yes (on update/delete)                  | Yes                   | No (full overwrite)              |
| **TaskCategory** | Yes (`version` field)    | Yes (on reorder)                        | **No**                | No                               |

### 同步触发条件

| Trigger                      | When                | What syncs                                     |
| ---------------------------- | ------------------- | ---------------------------------------------- |
| `performInitialSync()`       | App startup (once)  | categories → recipes → meals/tasks (full)      |
| Beat flag `meal_recipe`      | Heartbeat (15s TTL) | All recipes per category                       |
| Beat flag `meal` / `task`    | Heartbeat (15s TTL) | Meals / Tasks                                  |
| MealPage / TasksPage open    | User navigates      | **Nothing** (only if categories empty)         |

### 核心风险

Beat flag 是**唯一的**增量同步触发机制。如果错过（app 进入后台、网络抖动、TTL 过期），数据将一直不一致，直到 app 重启。

---

## 方案：写入时存储指纹 + 差异同步

### 核心思路

每种 model 维护一个**持久化的数据指纹（fingerprint）**，**仅在写入时计算**。Heartbeat 返回预计算好的指纹，零开销。检测到不匹配时，执行**差异同步**（非全量同步），只拉取实际变化的记录。

### 设计原则

1. **写入时计算，读取时不算** — 指纹仅在数据变更（CRUD 操作）时重新计算，heartbeat 查询时从不计算。数据一天最多变化几十次，heartbeat 每 5 秒一次。
2. **不匹配时差异同步** — 不做全量同步，而是服务端发送 `[(id, version)]` 列表，pad 本地比对后只拉取差异记录。
3. **两端都缓存** — 服务端将指纹存入 DB + Redis；Pad 在内存中缓存，仅在本地 DB 变化后重算。

### 详细设计

#### 1. 服务端：指纹模型

新建模型，存储每用户每模型的指纹：

```python
# pronext/common/models.py

class DataFingerprint(models.Model):
    """存储预计算的数据指纹。

    每次写入操作（create/update/delete）时更新。
    每次 heartbeat 响应时读取（零计算）。
    """
    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    model_type = models.CharField(max_length=20)  # 'recipe', 'meal', 'task'
    fingerprint = models.CharField(max_length=8, default='')
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('user', 'model_type')
        indexes = [
            models.Index(fields=['user']),
        ]
```

指纹计算工具函数：

```python
import hashlib

def compute_fingerprint(model_class, user_id):
    """计算 MD5 指纹（8字符），基于用户的所有记录。"""
    rows = (
        model_class.objects
        .filter(user_id=user_id)
        .values_list('id', 'version')
        .order_by('id')
    )
    content = ",".join(f"{pk}:{ver}" for pk, ver in rows)
    return hashlib.md5(content.encode()).hexdigest()[:8]


def update_fingerprint(model_type, model_class, user_id):
    """重算并存储指纹。在任何 CRUD 操作后调用。"""
    fp = compute_fingerprint(model_class, user_id)
    DataFingerprint.objects.update_or_create(
        user_id=user_id,
        model_type=model_type,
        defaults={'fingerprint': fp},
    )
    # 同时写入 Redis，加速 heartbeat 读取
    cache.set(f':1:fp:{user_id}:{model_type}', fp, timeout=None)  # 不过期
    return fp
```

**何时调用 `update_fingerprint()`：**

每个执行 Recipe/Meal/Task 增删改的 Django view 在操作结束后调用：

```python
# 示例：viewset_pad.py RecipeViewSet._update()
count = Recipe.objects.filter(id=pk, user_id=device_id).update(
    version=F('version') + 1, **serializer.validated_data
)
if count:
    update_fingerprint('recipe', Recipe, device_id)
    beat.should_refresh_meal_recipe(True)
```

**Heartbeat 响应 — 只读，不计算：**

```python
# 在 heartbeat serializer 或 view 中
def get_fingerprints(user_id):
    """读取预计算的指纹。Redis 命中时零 DB 查询。"""
    fps = {}
    for model_type in ('recipe', 'meal', 'task'):
        # 优先读 Redis
        fp = cache.get(f':1:fp:{user_id}:{model_type}')
        if fp is None:
            # Redis 未命中（冷启动 / flush）— 从 DB 读取并回填缓存
            try:
                obj = DataFingerprint.objects.get(user_id=user_id, model_type=model_type)
                fp = obj.fingerprint
                cache.set(f':1:fp:{user_id}:{model_type}', fp, timeout=None)
            except DataFingerprint.DoesNotExist:
                fp = ''  # 尚无数据
        fps[model_type] = fp
    return fps
```

**Heartbeat 响应格式：**

```json
{
  "event_cate": false,
  "meal_recipe": false,
  "meal": false,
  "task": false,
  "fp": {
    "recipe": "a1b2c3d4",
    "meal": "e5f6a7b8",
    "task": "c9d0e1f2"
  }
}
```

#### 2. 服务端：差异同步接口

新接口，返回 `(id, version)` 列表供 pad 比对：

```
GET /pad-api/sync/diff?models=recipe,meal,task
```

响应：

```json
{
  "recipe": {
    "fp": "a1b2c3d4",
    "items": [[1, 3], [2, 1], [5, 7], [8, 2]]
  },
  "meal": {
    "fp": "e5f6a7b8",
    "items": [[10, 1], [11, 4], [12, 2]]
  },
  "task": {
    "fp": "c9d0e1f2",
    "items": [[20, 5], [21, 1]]
  }
}
```

每个 `items` 元素为 `[id, version]`。数据量极小：1000 条记录约 10 KB。

Pad 收到后：

1. 与本地 Room 数据比对
2. 识别出：**本地缺失**（需拉取）、**version 不同**（需拉取）、**本地多余**（需删除）
3. 通过已有 API 的 `?ids=1,5,8` 参数只拉取变化的记录
4. 同步完成后重算本地指纹，验证是否与服务端一致

#### 3. Pad 端：缓存本地指纹

```kotlin
// 在每个 Manager 中（MealManager, TaskManager）

private var localFingerprints = mutableMapOf<String, String>()

/**
 * 重算并缓存本地指纹。
 * 仅在本地 DB 变化后调用（同步完成、本地编辑）。
 */shi
suspend fun refreshLocalFingerprint(model: String) {
    val rows = when (model) {
        "recipe" -> recipeDao.getAllIdVersionPairs()
        "meal" -> mealDao.getAllIdVersionPairs()
        "task" -> taskDao.getAllIdVersionPairs()
        else -> emptyList()
    }
    val content = rows.sortedBy { it.first }
        .joinToString(",") { "${it.first}:${it.second}" }
    localFingerprints[model] = md5(content).substring(0, 8)
}
```

**DAO 查询：**

```kotlin
@Query("SELECT id, version FROM recipes WHERE syncStatus = 'SYNCED' ORDER BY id")
suspend fun getAllIdVersionPairs(): List<IdVersionPair>

data class IdVersionPair(val id: Long, val version: Int)
```

#### 4. Heartbeat 信号处理：比对 + 差异同步

```kotlin
Signal.add(Signal.Key.HeartBeat) {
    val beat = it["beat"] as? Beat ?: return@add
    val fp = it["fp"] as? Map<String, String>

    // 快速路径：beat flag（已有逻辑）
    if (beat.meal_recipe) {
        syncAllRecipesFromServer()
        refreshLocalFingerprint("recipe")
    }
    if (beat.meal) {
        syncMealsFromServer()
        refreshLocalFingerprint("meal")
    }
    if (beat.task) {
        syncTasksFromServer()
        refreshLocalFingerprint("task")
    }

    // 慢速路径：指纹验证（捕获遗漏的 beat flag）
    fp?.let { serverFps ->
        scope.launch(Dispatchers.IO) {
            val mismatched = serverFps.filter { (model, serverFp) ->
                localFingerprints[model] != serverFp
            }.keys

            if (mismatched.isNotEmpty()) {
                Log.w(TAG, "指纹不匹配: $mismatched — 触发差异同步")
                performDifferentialSync(mismatched)
            }
        }
    }
}
```

**差异同步流程：**

```kotlin
suspend fun performDifferentialSync(models: Set<String>) {
    // 1. 从服务端获取 (id, version) 列表
    val diff = api.getSyncDiff(models.joinToString(","))

    for (model in models) {
        val serverItems = diff[model]?.items ?: continue  // List<[id, version]>
        val localItems = when (model) {
            "recipe" -> recipeDao.getAllIdVersionPairs()
            "meal" -> mealDao.getAllIdVersionPairs()
            "task" -> taskDao.getAllIdVersionPairs()
            else -> continue
        }

        val localMap = localItems.associate { it.id to it.version }
        val serverMap = serverItems.associate { it[0] to it[1] }

        // 本地缺失或版本落后的记录 → 需要拉取
        val toFetch = serverMap.filter { (id, ver) ->
            localMap[id] == null || localMap[id]!! < ver
        }.keys

        // 本地多余的记录（服务端已删除）→ 需要删除
        val toDelete = localMap.keys - serverMap.keys

        // 2. 只拉取变化的记录
        if (toFetch.isNotEmpty()) {
            fetchRecordsByIds(model, toFetch.toList())
        }

        // 3. 删除本地孤儿记录
        if (toDelete.isNotEmpty()) {
            deleteLocalRecords(model, toDelete.toList())
        }

        // 4. 重算本地指纹并验证
        refreshLocalFingerprint(model)
        if (localFingerprints[model] != diff[model]?.fp) {
            Log.e(TAG, "$model: 差异同步后指纹仍不匹配，回退到全量同步")
            performFullSync(model)
            refreshLocalFingerprint(model)
        }
    }
}
```

#### 5. 流程图

```
数据写入（create/update/delete）
    |
    +-- 更新 DB 记录
    +-- 重算指纹 → 存入 DB + Redis
    +-- 设置 beat flag（已有逻辑）

Heartbeat 响应（每 5s）
    |
    +-- 从 Redis 读取 beat flags（已有）
    +-- 从 Redis 读取指纹（仅 GET，无计算）
    +-- 返回给 pad

Pad 收到 Heartbeat
    |
    +-- Beat flag 已设置？ ----是----> 定向同步 → 刷新本地指纹
    |
    +-- 比对服务端指纹 vs 本地缓存指纹
            |
            +-- 匹配 ----> 无需操作
            |
            +-- 不匹配 -> 差异同步：
                    1. GET /sync/diff → [(id, version)] 列表
                    2. 与本地 Room 比对
                    3. 只拉取变化的记录
                    4. 删除本地孤儿记录
                    5. 验证指纹是否一致
                    6. 仍不一致 → 全量同步（兜底）
```

---

## 前置修复

### 修复 1：Recipe version 未递增

**需修改的服务端文件：**

`server/pronext/meal/viewset_pad.py` — RecipeViewSet._update()：

```python
# 修改前 (line 140):
count = Recipe.objects.filter(id=pk, user_id=device_id).update(**serializer.validated_data)

# 修改后:
count = Recipe.objects.filter(id=pk, user_id=device_id).update(
    version=F('version') + 1, **serializer.validated_data
)
```

`server/pronext/meal/viewset_app.py` — RecipeViewSet._update()：

```python
# 修改前 (line 128):
count = Recipe.objects.filter(id=pk, user_id=device_id).update(**serializer.validated_data)

# 修改后:
count = Recipe.objects.filter(id=pk, user_id=device_id).update(
    version=F('version') + 1, **serializer.validated_data
)
```

### 修复 2：Task complete_task 应递增 version

`server/pronext/task/options.py` — complete_task()：

```python
# 修改前 (line 227):
Task.objects.filter(user_id=device_id, id=task_id).update(completeds=completeds)

# 修改后:
Task.objects.filter(user_id=device_id, id=task_id).update(
    version=F('version') + 1, completeds=completeds
)
```

否则在手机上完成任务不会改变 version，指纹不会反映这个变化，pad 不会知道需要重新同步。

### 修复 3：CategoryEntity 需要 version 字段（Meal 和 Task）

在 Pad Room DB 的 `CategoryEntity` 和 `TaskCategoryEntity` 中添加 `version` 字段。在服务端的 `TaskCategorySerializer` 中添加 `version` 到 fields。确保分类变更也可追踪。

指纹同步不强制要求此项（分类数据量小，全量覆盖即可），但补全了 version 追踪体系。

---

## 诊断：如何检查 Room vs Server 数据

当用户反馈"手机上有 X 但 pad 上没有"：

### 方案 A：服务端诊断接口

添加诊断接口（仅管理员或设备认证）：

```
GET /pad-api/diagnostic/sync-status
```

响应：

```json
{
  "device_id": 777,
  "recipes": {"count": 36, "fingerprint": "a1b2c3d4"},
  "meals": {"count": 12, "fingerprint": "e5f6a7b8"},
  "tasks": {"count": 8, "fingerprint": "c9d0e1f2"}
}
```

Pad 也可以暴露本地指纹（通过 debug 菜单或日志）。两者对比可以立即定位哪个模型不同步。

### 方案 B：Pad 调试界面

在 Pad 设置中添加"同步诊断"按钮（开发者区域）：

1. 计算所有模型的本地指纹
2. 通过诊断接口获取服务端指纹
3. 显示对比结果：

   ```
   Recipe: 本地=a1b2c3d4 服务端=a1b2c3d4 OK
   Meal:   本地=e5f6a7b8 服务端=ff000000 不匹配 → 点击强制同步
   Task:   本地=c9d0e1f2 服务端=c9d0e1f2 OK
   ```

---

## 实施计划

### 阶段 1：修复 Version Bug（Server — 1 PR）

1. Recipe update：添加 `version=F('version') + 1`
2. Task complete：添加 `version=F('version') + 1`
3. `TaskCategorySerializer` fields 中添加 `version`

### 阶段 2：服务端指纹存储 + 差异同步接口（Server — 1 PR）

1. 新建 `DataFingerprint` 模型 + migration
2. 实现 `compute_fingerprint()` / `update_fingerprint()` 工具函数
3. 在所有 Recipe/Meal/Task CRUD viewset 中调用 `update_fingerprint()`
4. 新建 `GET /pad-api/sync/diff` 接口
5. Heartbeat 响应中包含 `fp`（从 Redis 读取，fallback 到 DB）
6. 新建诊断接口
7. Management command 回填现有数据的指纹

### 阶段 3：Pad 端指纹比对 + 差异同步（Pad — 1 PR）

1. 添加 `IdVersionPair` 和 DAO 查询
2. 在 Manager 中添加本地指纹缓存
3. 解析 heartbeat 响应中的 `fp`
4. 实现 `performDifferentialSync()`
5. 添加 `GET /sync/diff` API 调用
6. 差异同步失败时回退到全量同步
7. （可选）设置中的调试界面

### 阶段 4：Go Heartbeat 服务（Go — 1 PR）

1. 从 Redis 读取指纹（Django 已写入）
2. Go heartbeat 响应中包含 `fp`
3. Go 端不做任何计算 — 只读 Redis

---

## 性能对比

### 旧方案（已否决）

| Operation           | Frequency                            | Cost                         |
| ------------------- | ------------------------------------ | ---------------------------- |
| Compute fingerprint | Every heartbeat (5s) x every device  | 3 DB queries per heartbeat   |
| Pad compute hash    | Every heartbeat (5s)                 | 3 Room queries per heartbeat |
| Sync on mismatch    | On mismatch                          | Full sync (all records)      |

### 新方案

| Operation           | Frequency                         | Cost                                     |
| ------------------- | --------------------------------- | ---------------------------------------- |
| Compute fingerprint | Only on data write (~few per day) | 1 DB query per write                     |
| Store fingerprint   | Only on data write                | 1 DB upsert + 1 Redis SET               |
| Heartbeat read fp   | Every heartbeat (5s)              | 3 Redis GETs (sub-ms, no DB)             |
| Pad compare fp      | Every heartbeat (5s)              | 3 string comparisons (in-memory)         |
| Sync on mismatch    | On mismatch                       | Differential: fetch only changed records |

**节省量**：消除 ~99.9% 的无效 DB 查询。一台设备 5s heartbeat 间隔，一天产生 17,280 次 heartbeat — 旧方案下仅指纹就需要 51,840 次 DB 查询/天/设备。新方案下约 0 次（仅 Redis GET）。

## 为什么不在每次打开页面时全量同步？

- 每次 recipe 同步 = 每个分类 1 个 API 调用（4 个分类 = 4 次调用）
- 每次 meal 同步 = 1 个 API 调用
- 每次 task 同步 = 1 个 API 调用
- 合计：每次页面导航约 6 个 API 调用
- 慢网络下明显增加延迟，影响用户体验
- 指纹方案：0 额外 API 调用（搭载在 heartbeat 上）+ 仅在数据确实不一致时才同步

## 为什么不用简单的递增计数器？

用一个单调递增的计数器代替哈希，虽然更便宜，但有一个致命缺陷：**它无法验证同步是否成功**。如果同步中途被打断（网络超时、app 被杀），pad 可能已经更新了本地计数器但数据仍不完整。哈希方案验证的是实际数据一致性 — 两端从相同的源数据独立计算出相同的指纹，匹配就意味着数据完全一致。
