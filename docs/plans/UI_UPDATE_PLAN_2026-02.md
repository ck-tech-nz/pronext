# UI 更新开发计划 — 2026年2月

> 基于最新设计稿（`UI/new_ui/`），涵盖 6 个页面的视觉与交互升级。
> 本文档可指导 AI 全程自主开发、自测、验收。

---

## 1. 设计变更总览

### 1.1 涉及页面清单

| # | 页面 | 设计稿文件 | 主要承载端 | 变更级别 |
|---|------|-----------|-----------|---------|
| A | My Calendars（首页设备列表） | `Calendar-Home-v2.png` | Flutter + Vue | **重构** |
| B | Calendar Dashboard（日历主面板） | `Calendar-Home.png` | Vue (H5) | **改版** |
| C | Welcome / Add Calendar（欢迎引导页） | `Home-Add-Calendar.png` | Vue (H5) | **新建** |
| D | Join Family Calendar（加入家庭日历） | `Join-Family-Calendar.png` | Vue (H5) | **改版** |
| E | Profile（用户个人资料） | `Profile.png` | Vue (H5) | **微调** |
| F | Settings（日历设置） | `Settings-v2.png` | Vue (H5) | **改版** |

### 1.2 术语统一

新设计在术语上做了统一调整，全局需要替换：

| 旧术语 | 新术语 | 影响范围 |
|--------|--------|---------|
| My Devices | My Calendars | 首页标题、导航、路由 |
| Device | Calendar | 除物理 Pad 设备外的所有场景 |
| Add Device | Add Calendar | Profile 页 CTA、引导页 |
| Todo List / Lists | Lists | Dashboard 功能入口 |
| Linked Devices | Linked Devices (Frames) | Settings 页保持不变 |

---

## 2. 逐页需求分析

### 页面 A：My Calendars（首页设备列表）— Flutter + Vue

**设计稿：** `Calendar-Home-v2.png`

**当前实现：**
- Flutter `Home` 页渲染设备列表（`DeviceManager.devices`）
- 显示设备名称、email、shared 信息
- 点击设备 → WebView 加载 H5 Dashboard

**新设计变更点：**

1. **标题** 由 "My Devices" → "My Calendars"
2. **设备卡片重新设计**
   - 显示绿色在线状态指示灯 + "Online" 文字标签
   - 显示设备序列号（SN: PNXT-2024-00A1）
   - 日期标题 + 事件数量 badge（"2 events"）
   - 当日事件预览列表（带左侧彩色竖线，最多显示 2-3 条）
3. **Quick Actions 网格**（2×2）
   - Calendar（1 Event Today）
   - Chores（3 Remaining）
   - Photos（160 Photos）
   - Sync（2 Calendars）
4. **底部固定按钮** "Manage Calendar >"
5. **分页指示器**（圆点分页，暗示多设备可横滑切换）
6. **Profile 头像** 在左上角（当前已有）
7. **去掉了 Notifications 铃铛图标的角标红点**（变为三点菜单）

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| A-1 | 首页标题改为 "My Calendars" | Flutter | 0.5h |
| A-2 | 新增设备在线状态显示（绿点 + Online 标签） | Flutter | 2h |
| A-3 | 设备卡片增加 SN 序列号显示 | Flutter | 1h |
| A-4 | 卡片增加当日日期 + 事件数量 badge | Flutter | 2h |
| A-5 | 卡片增加当日事件预览（最多 2-3 条） | Flutter | 3h |
| A-6 | Quick Actions 2×2 网格（Calendar / Chores / Photos / Sync） | Flutter | 3h |
| A-7 | 底部固定 "Manage Calendar" 按钮 | Flutter | 1h |
| A-8 | 多设备横向分页滑动 + 圆点指示器 | Flutter | 3h |
| A-9 | 右上角三点菜单替换 Notifications 铃铛 | Flutter | 1h |
| A-10 | 后端 API：`/device/home/{id}` 增返回 SN、online_status | Server | 2h |

**依赖的 API 变更：**
- `GET /app-api/device/list` — 需返回 `sn`、`online_status` 字段
- `GET /app-api/device/home/{id}` — 需返回今日事件摘要、各模块计数
- 在线状态已存在 Redis key `device:online_status:{device_sn}`，需在 list 接口中聚合

---

### 页面 B：Calendar Dashboard（日历主面板）— Vue H5

**设计稿：** `Calendar-Home.png`

**当前实现：**
- Vue `Dashboard.vue`（`/device/dashboard/:device_id`）
- 日期标题 + 事件列表 + 3×3 功能网格 + pull-to-refresh

**新设计变更点：**

1. **页面标题** 显示日历名称（如 "Tester Calendar"）而非 Logo
2. **导航栏** 增加左侧返回箭头
3. **事件区域改版**
   - 无事件时：浅绿卡片 "No upcoming events today"
   - 有事件时：浅绿卡片显示事件标题 + 时间（如 "After turning your Calendar on, 2:00 PM - 3:00 PM"）
4. **功能网格变更**（2×3 布局）
   - Calendar（1 Event Today）
   - Chores（3 Chores Remaining）
   - Photos（160 Photos）
   - Lists（0 List）—— 原 "Todo List" 改名
   - Sync（Sync Online Calendars）
   - Settings（Adjust your app）—— **新增入口**
   - **移除：** Share、Profiles、Meal Plan
5. **底部** 显示支持邮箱 "support: info@pronextusa.com"（已有，拼写修正 "suuport" → "support"）

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| B-1 | Dashboard 标题改为显示日历名称 | Vue | 0.5h |
| B-2 | 增加左侧返回箭头导航 | Vue | 0.5h |
| B-3 | 事件区域 UI 重构（卡片式，空/有事件双状态） | Vue | 3h |
| B-4 | 功能网格从 3×3 改为 2×3，更新项目 | Vue | 2h |
| B-5 | "Todo List" 改名为 "Lists" | Vue | 0.5h |
| B-6 | 新增 "Settings" 功能入口 → `/settings/:device_id` | Vue | 0.5h |
| B-7 | 移除 Share / Profiles / Meal Plan 入口 | Vue | 0.5h |
| B-8 | 修复底部 "suuport" 拼写 → "support" | Vue | 0.1h |
| B-9 | 图标样式更新匹配设计稿 | Vue | 2h |

---

### 页面 C：Welcome / Add Calendar（欢迎引导页）— Vue H5

**设计稿：** `Home-Add-Calendar.png`

**当前实现：**
- Vue `Add.vue`（`/device/add`）— 简单选项卡片（Yes/No 两项）
- 标题 "Are you activating a new Pronext Calendar?"

**新设计变更点：**

1. **全新页面布局** — 欢迎风格引导页
2. **顶部** 显示 Pronext Logo + Profile 头像
3. **欢迎文案** "Welcome to Pronext! 👋" + "Your smart family calendar starts here"
4. **设备示意图** 彩色柱状图示意
5. **选项卡片**（单选 radio 风格）
   - "I have a Pronext Device" — Get an activation code for your device ✓
   - "Join a family calendar" — Enter a share link from your family ○
6. **底部** "Continue →" 蓝色按钮
7. **提示** "You can change this later in settings"

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| C-1 | 重写 Add.vue 页面为欢迎引导风格 | Vue | 4h |
| C-2 | Radio 选择卡片组件（单选高亮） | Vue | 1.5h |
| C-3 | 设备示意插图（静态 SVG/PNG） | Vue | 0.5h |
| C-4 | Continue 按钮逻辑：选项1 → `/device/create`，选项2 → `/device/find-calendar` | Vue | 1h |
| C-5 | "You can change this later in settings" 提示文字 | Vue | 0.2h |

---

### 页面 D：Join Family Calendar（加入家庭日历）— Vue H5

**设计稿：** `Join-Family-Calendar.png`

**当前实现：**
- Vue `FindCalendar.vue`（`/device/find-calendar`）— 简单输入框 + Done 按钮

**新设计变更点：**

1. **页面标题** 改为 "Pronex"（设计稿如此，需确认是否为 "Pronext" 的笔误）
2. **卡片容器** 包裹标题 + 输入框 + 按钮
   - 标题 "Find existing Calendar"（注意 "Calendar" 而非 "Calenda"，设计稿有拼写问题）
   - 副标题 "Add a loved one's Calendar by pasting the share link below."
   - 输入框 placeholder "paste or enter the share link"
   - "Done" 按钮（浅蓝色渐变背景）
3. **帮助引导区域**（新增）
   - "How to get the share link?" 标题（带 ⓘ 图标）
   - 3 步文字说明：
     1. Ask the calendar owner to open the Pronext app
     2. Tap the share button on the top right
     3. They can copy or send the link to you directly
   - **截图示例** 展示 Step 2 和 Step 3 的操作界面

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| D-1 | 重构 FindCalendar.vue 页面布局（卡片式） | Vue | 2h |
| D-2 | 输入框 + Done 按钮样式更新 | Vue | 1h |
| D-3 | 新增 "How to get the share link?" 帮助引导区域 | Vue | 2h |
| D-4 | 步骤截图展示（静态图片资源） | Vue | 1h |
| D-5 | 确认 "Pronex" 是否应为 "Pronext"，修正拼写 | Vue | 0.2h |

---

### 页面 E：Profile（用户个人资料）— Vue H5

**设计稿：** `Profile.png`

**当前实现：**
- Vue `Profile.vue`（`/profile`）
- Account 区块 + Notifications 区块 + Logout + Delete Account

**新设计变更点：**

1. **Account 区块** 基本不变（Email / Name / Phone / Birthday / Password）
2. **Notifications 区块** 基本不变
   - Open Push Notifications Setting
   - Send By Email（toggle）
   - Marketing Promotion（toggle）
3. **CTA 按钮改名** "Add Device →" → "Add Calendar →"（样式：蓝色描边按钮带日历图标）
4. **移除：** "Find Support" 和 "About" 入口
5. **保留：** Logout 按钮 + DANGER ZONE: Delete Account

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| E-1 | CTA 按钮文字改为 "Add Calendar →" | Vue | 0.3h |
| E-2 | CTA 按钮样式更新（蓝色描边 + 日历图标） | Vue | 0.5h |
| E-3 | 移除 "Find Support" 入口 | Vue | 0.2h |
| E-4 | 移除 "About" 入口 | Vue | 0.2h |
| E-5 | Birthday 字段确认编辑交互（设计稿仅显示铅笔图标） | Vue | 0.5h |

---

### 页面 F：Settings（日历设置）— Vue H5

**设计稿：** `Settings-v2.png`

**当前实现：**
- Vue `Settings.vue`（`/settings/:device_id`）
- Notifications 设置 + Linked Devices 列表

**新设计变更点：**

1. **Notifications 区块** 基本保持（At time of event / minutes before / slider）
   - 样式微调：slider 蓝色主题
2. **Linked Devices (Frames) 区块** 保持基本结构
   - 显示绿色在线状态点
   - 显示 timezone（如 "America/New_York"）
   - "Link new device" 按钮（蓝色实心）
   - 增加描述文字说明 Linked Devices 的用途
3. **新增 Family Sharing 区块**
   - 标题 "Family Sharing"（带人物图标）
   - 说明文字 "Share your calendar account with family members so you can manage events and schedules together."
   - "Share Calendar" 按钮（蓝色实心）
   - 点击后应跳转到设备分享流程

**开发任务：**

| 任务ID | 描述 | 端 | 预估 |
|--------|------|----|------|
| F-1 | Notifications 区块样式微调（蓝色 slider） | Vue | 0.5h |
| F-2 | Linked Devices 增加在线状态指示 + timezone 显示 | Vue | 1.5h |
| F-3 | Linked Devices 增加用途说明文字 | Vue | 0.3h |
| F-4 | **新增 Family Sharing 区块**（标题 + 说明 + Share Calendar 按钮） | Vue | 2h |
| F-5 | Share Calendar 按钮联动到分享流程 `/device/share/:device_id` | Vue | 1h |
| F-6 | "Link new device" 按钮样式更新（蓝色实心） | Vue | 0.3h |

---

## 3. 后端 API 变更需求

| # | 端点 | 变更类型 | 描述 |
|---|------|---------|------|
| API-1 | `GET /app-api/device/list` | 修改 | 返回增加 `sn`、`online_status` 字段 |
| API-2 | `GET /app-api/device/home/{id}` | 修改 | 返回今日事件摘要（标题+时间，最多3条）、各模块计数统一 |
| API-3 | `GET /app-api/device/{id}/linked-devices` | 修改 | 返回增加 `online_status`、`timezone` 字段 |
| API-4 | （可选）Family Sharing 独立 API | 新增 | 如果 Family Sharing 流程与当前 `refresh-link` 不同，需要新增端点 |

> 注意：大部分数据已存在于后端，主要是接口返回字段的补充。`online_status` 从 Redis key `device:online_status:{device_sn}` 读取即可。

**新增字段类型规范：**

| 字段 | 类型 | 示例值 | 说明 |
|------|------|--------|------|
| `sn` | String | `"PNXT-2024-00A1"` | 设备序列号，来自 PadDevice 表 |
| `online_status` | Boolean | `true` / `false` | 从 Redis 读取，key 不存在时为 false |
| `today_events` | Array | `[{title, start_time, end_time, color}]` | 最多 3 条，color 为 hex 值如 `"#fdf1db"` |
| `today_events[].title` | String | `"Team Standup Meeting"` | 事件标题 |
| `today_events[].start_time` | String | `"09:00"` | HH:mm 格式 |
| `today_events[].end_time` | String | `"09:30"` | HH:mm 格式 |
| `today_events[].color` | String | `"#daf6f4"` | category 色值，hex 格式 |
| `calendar_count` | Integer | `1` | 今日日历事件数 |
| `chores_count` | Integer | `3` | 剩余未完成 chores 数 |
| `photos_count` | Integer | `160` | 照片总数 |
| `sync_count` | Integer | `2` | 已同步日历数 |
| `timezone` | String | `"America/New_York"` | IANA 时区格式 |

---

## 4. 开发步骤（按阶段推进）

### Phase 0：准备工作（0.5 天）

```
Step 0.1  阅读本文档，对照 UI/new_ui/ 设计稿确认每页变更
Step 0.2  在 server 中确认 online_status Redis key 数据可用性
Step 0.3  创建开发分支
          - vue:    git checkout -b feature/ui-update-2026-02
          - flutter: git checkout -b feature/ui-update-2026-02
          - server:  git checkout -b feature/ui-update-2026-02
```

### Phase 1：后端 API 补充（1 天）

```
Step 1.1  server: 修改 device list 序列化器，增加 sn、online_status
Step 1.2  server: 修改 device home 接口，增加今日事件摘要
Step 1.3  server: 修改 linked-devices 接口，增加 online_status、timezone
Step 1.4  编写单元测试验证新字段
Step 1.5  本地测试 API 响应结构
```

### Phase 2：Vue H5 页面更新（3-4 天）

**2a. 低影响页面（1 天）**

```
Step 2.1  页面 E — Profile: 修改 CTA 按钮文字和样式，移除多余入口
Step 2.2  页面 B — Dashboard: 标题改日历名称、增加返回箭头、功能网格调整
Step 2.3  页面 B — Dashboard: 事件区域 UI 重构（卡片式双状态）
Step 2.4  全局术语替换："Device" → "Calendar"（路由名、显示文本）
```

**2b. 中影响页面（1-1.5 天）**

```
Step 2.5  页面 F — Settings: 新增 Family Sharing 区块
Step 2.6  页面 F — Settings: Linked Devices 样式优化 + online/timezone 显示
Step 2.7  页面 D — Join Family Calendar: 重构布局 + 新增帮助引导区域
Step 2.8  准备帮助引导所需的静态截图资源
```

**2c. 高影响页面（1-1.5 天）**

```
Step 2.9  页面 C — Welcome/Add Calendar: 全新页面开发
Step 2.10 页面 C — Radio 选择卡片组件 + Continue 逻辑
Step 2.11 图标和插图资源整理（SVG/PNG）
```

### Phase 3：Flutter 首页重构（2-3 天）

```
Step 3.1  首页标题 "My Calendars" + 右上角三点菜单
Step 3.2  设备卡片重构：在线状态、SN、日期标题、事件 badge
Step 3.3  设备卡片内嵌当日事件预览列表（带彩色竖线）
Step 3.4  Quick Actions 2×2 网格组件
Step 3.5  底部固定 "Manage Calendar" 按钮
Step 3.6  多设备横滑 PageView + 圆点指示器
Step 3.7  集成后端新字段（sn、online_status、today_events）
```

### Phase 4：联调与修缮（1 天）

```
Step 4.1  Flutter → WebView H5 页面间跳转联调
Step 4.2  Quick Actions 各入口路由验证
Step 4.3  Settings → Family Sharing → Share 流程联调
Step 4.4  Welcome 页 → Continue → 创建/加入 流程联调
Step 4.5  Profile → Add Calendar 跳转联调
Step 4.6  响应式布局在不同机型上验证（iOS / Android）
```

### Phase 5：测试与验收（1-2 天）

详见第 5 节。

---

## 5. 测试及验收步骤

### 5.1 自动化验证清单（AI 自测用）

以下清单供 AI 开发完成后逐项自验。每个检查点应标记 PASS/FAIL。

#### 后端 API 验证

```
[ ] T-API-1  GET /app-api/device/list 返回包含 sn 字段
[ ] T-API-2  GET /app-api/device/list 返回包含 online_status 字段（Boolean 或 String）
[ ] T-API-3  GET /app-api/device/home/{id} 返回 today_events 数组（含 title、start_time、end_time、color）
[ ] T-API-4  GET /app-api/device/home/{id} 返回各模块计数（calendar_count、chores_count、photos_count、sync_count）
[ ] T-API-5  GET /app-api/device/{id}/linked-devices 返回 online_status 和 timezone
[ ] T-API-6  所有现有单元测试通过 (python3 manage.py test)
[ ] T-API-7  新增字段的单元测试通过
```

#### 页面 A — My Calendars（Flutter）

```
[ ] T-A-1   首页标题显示 "My Calendars"
[ ] T-A-2   设备卡片显示绿色在线状态点 + "Online" 文字
[ ] T-A-3   设备卡片显示 SN 号（格式 "SN: PNXT-XXXX-XXXX"）
[ ] T-A-4   设备卡片显示当日日期（如 "Tuesday, June 4"）
[ ] T-A-5   设备卡片显示事件数量 badge（"2 events"）
[ ] T-A-6   设备卡片显示当日事件预览（标题 + 时间段 + 彩色左边框）
[ ] T-A-7   Quick Actions 网格显示 4 个入口：Calendar / Chores / Photos / Sync
[ ] T-A-8   每个 Quick Actions 显示对应计数信息
[ ] T-A-9   点击 Quick Actions 各项正确跳转到对应 H5 页面
[ ] T-A-10  底部固定 "Manage Calendar" 按钮可见且可点击
[ ] T-A-11  多设备时可横滑切换，底部圆点指示器联动
[ ] T-A-12  Profile 头像可点击进入个人资料页
[ ] T-A-13  右上角三点菜单可展开
[ ] T-A-14  下拉刷新正常工作，数据更新后 UI 同步
```

#### 页面 B — Calendar Dashboard（Vue）

```
[ ] T-B-1   页面标题显示日历名称（非 Logo）
[ ] T-B-2   左上角有返回箭头，点击返回上一页
[ ] T-B-3   无事件时显示浅绿卡片 "No upcoming events today"
[ ] T-B-4   有事件时显示事件卡片（标题 + 时间段）
[ ] T-B-5   功能网格为 2×3 布局：Calendar / Chores / Photos / Lists / Sync / Settings
[ ] T-B-6   "Lists" 入口文案正确（非 "Todo List"）
[ ] T-B-7   "Settings" 入口跳转到 /settings/:device_id
[ ] T-B-8   不再显示 Share / Profiles / Meal Plan 入口
[ ] T-B-9   底部支持邮箱拼写正确 "support: info@pronextusa.com"
[ ] T-B-10  各功能入口点击后正常跳转
```

#### 页面 C — Welcome / Add Calendar（Vue）

```
[ ] T-C-1   页面顶部显示 Pronext Logo + Profile 头像
[ ] T-C-2   显示 "Welcome to Pronext!" 欢迎标题
[ ] T-C-3   显示 "Your smart family calendar starts here" 副标题
[ ] T-C-4   显示设备示意插图
[ ] T-C-5   两个选项卡片：
            - "I have a Pronext Device" + 描述
            - "Join a family calendar" + 描述
[ ] T-C-6   默认选中第一项，蓝色选中态 + ✓ 图标
[ ] T-C-7   点击切换选项，单选互斥
[ ] T-C-8   Continue 按钮选择项1 → 跳转到 /device/create
[ ] T-C-9   Continue 按钮选择项2 → 跳转到 /device/find-calendar
[ ] T-C-10  底部显示 "You can change this later in settings"
```

#### 页面 D — Join Family Calendar（Vue）

```
[ ] T-D-1   页面以卡片容器包裹标题和输入区域
[ ] T-D-2   标题 "Find existing Calendar"（拼写正确）
[ ] T-D-3   副标题说明文字正确
[ ] T-D-4   输入框 placeholder "paste or enter the share link"
[ ] T-D-5   Done 按钮在空输入时禁用/灰态
[ ] T-D-6   输入有效链接后 Done 按钮可点击
[ ] T-D-7   提交有效链接成功加入日历 → 提示成功并返回首页
[ ] T-D-8   提交无效链接显示错误提示
[ ] T-D-9   "How to get the share link?" 帮助区域可见
[ ] T-D-10  三步文字说明内容正确
[ ] T-D-11  步骤截图正确显示
```

#### 页面 E — Profile（Vue）

```
[ ] T-E-1   Account 区块字段完整（Email / Name / Phone / Birthday / Password）
[ ] T-E-2   Notifications 区块含三项（Push Setting / Send By Email / Marketing）
[ ] T-E-3   CTA 按钮显示 "Add Calendar →"（非 "Add Device"）
[ ] T-E-4   CTA 按钮为蓝色描边样式 + 日历图标
[ ] T-E-5   点击 "Add Calendar" 跳转到添加日历流程
[ ] T-E-6   不再显示 "Find Support" 入口
[ ] T-E-7   不再显示 "About" 入口
[ ] T-E-8   Logout 按钮功能正常
[ ] T-E-9   Delete Account 在 DANGER ZONE 正常显示并可操作
```

#### 页面 F — Settings（Vue）

```
[ ] T-F-1   Notifications 区块：At time of event toggle 可操作
[ ] T-F-2   Notifications 区块：minutes before toggle 可操作
[ ] T-F-3   Notifications 区块：slider 蓝色主题，可拖动
[ ] T-F-4   Linked Devices 标题含 "(Frames)" 标注
[ ] T-F-5   每个 Linked Device 显示绿色在线状态点
[ ] T-F-6   每个 Linked Device 显示 timezone 信息
[ ] T-F-7   Linked Devices 区域有用途说明文字
[ ] T-F-8   "Link new device" 按钮蓝色实心样式，点击有效
[ ] T-F-9   **Family Sharing 区块可见**
[ ] T-F-10  Family Sharing 显示人物图标 + 标题 + 说明文字
[ ] T-F-11  "Share Calendar" 按钮蓝色实心样式
[ ] T-F-12  点击 "Share Calendar" 跳转到设备分享流程
```

### 5.2 跨页面流程测试

```
[ ] T-FLOW-1  新用户首次登录 → Profile → Add Calendar → Welcome → 选择 "I have a device" → Continue → Create → Activate → 返回首页 → 看到新日历卡片
[ ] T-FLOW-2  新用户首次登录 → Profile → Add Calendar → Welcome → 选择 "Join family" → Continue → Find Calendar → 粘贴链接 → Done → 返回首页 → 看到日历卡片
[ ] T-FLOW-3  首页点击日历卡片 → 进入 Dashboard → 点击 Settings → 进入 Settings 页 → 看到 Family Sharing → 点击 Share Calendar
[ ] T-FLOW-4  首页点击日历卡片 → Dashboard → 点击 Calendar → 日历页面正常
[ ] T-FLOW-5  首页点击日历卡片 → Dashboard → 点击 Lists → Lists 页面正常
[ ] T-FLOW-6  首页多设备横滑 → 切换到第二个设备 → 数据正确刷新
[ ] T-FLOW-7  首页 Quick Actions 各按钮跳转后可正常返回首页
[ ] T-FLOW-8  Settings → Link new device → 激活流程正常
[ ] T-FLOW-9  Profile → Logout → 重新登录 → 首页显示正常
```

### 5.3 视觉验收标准

```
[ ] T-VIS-1   所有页面背景使用统一渐变背景图（bg.png）
[ ] T-VIS-2   卡片圆角、阴影与设计稿一致（rounded-2xl shadow-sm）
[ ] T-VIS-3   在线状态点颜色为 #22c55e（绿色）
[ ] T-VIS-4   事件预览左侧竖线颜色匹配事件 category 色值
[ ] T-VIS-5   按钮样式一致：蓝色实心（#3B82F6）/ 蓝色描边
[ ] T-VIS-6   功能网格图标风格统一（线条图标）
[ ] T-VIS-7   页面在 iPhone SE (375px) 和 iPhone 15 Pro Max (430px) 上均正常显示
[ ] T-VIS-8   Safe Area 适配正确（刘海屏、底部安全区）
[ ] T-VIS-9   暗色模式适配（如果有）
```

### 5.4 异常与边界测试

```
[ ] T-ERR-1   网络断开时首页显示合理提示（非白屏）
[ ] T-ERR-2   API 超时（>10s）时有 loading 和错误提示
[ ] T-ERR-3   页面 D：输入格式错误的链接显示明确错误信息
[ ] T-ERR-4   页面 C：未选择选项直接点 Continue 时有合理处理（默认选中第一项）
[ ] T-ERR-5   设备离线时首页不显示 "Online" 标签（或显示 "Offline" 灰色状态）
[ ] T-ERR-6   无事件日历的 Quick Actions 计数正确显示 0
[ ] T-ERR-7   API 返回空 today_events 数组时页面 A 不崩溃
```

### 5.5 回归测试

```
[ ] T-REG-1   现有日历事件 CRUD 功能正常
[ ] T-REG-2   Chores 功能入口及操作正常
[ ] T-REG-3   Photos 上传和浏览正常
[ ] T-REG-4   Sync 功能正常（Google/Outlook/iCloud）
[ ] T-REG-5   Push 通知正常接收
[ ] T-REG-6   Pull-to-refresh 正常刷新数据
[ ] T-REG-7   WebView 与 Flutter 桥接通信正常（storage/routing/media）
[ ] T-REG-8   登录/注册/密码重置流程正常
[ ] T-REG-9   设备激活码生成与使用正常
```

---

## 6. AI 自监督开发指南

本节指导 AI 在全程开发中如何自我监督和验收。

### 6.1 开发前检查

```
开始每个 Phase 前：
1. 阅读本文档对应章节
2. 对照设计稿 UI/new_ui/ 中的 PNG 确认视觉目标
3. 检查当前代码状态（git status, npm run build, flutter build）
4. 确认依赖的上游变更已完成（如 Phase 2 需 Phase 1 的 API 变更）
```

### 6.2 开发中检查

```
完成每个 Step 后：
1. 运行 lint 检查（Vue: npm run lint, Flutter: flutter analyze）
2. 确认页面可正常渲染（无白屏、无 JS 报错）
3. 对照本文档的测试清单逐项确认
4. 截屏或记录当前 UI 状态（可选）
```

### 6.3 阶段验收

```
完成每个 Phase 后：
1. 运行所有测试（后端: python3 manage.py test, 前端: npm run build）
2. 对照第 5 节测试清单，标记每项 PASS/FAIL
3. 如有 FAIL 项，记录问题描述并修复后重新验证
4. 确认无回归问题（第 5.4 节清单）
5. 提交 git commit，附带变更说明
```

### 6.4 关键文件路径索引

便于 AI 快速定位需修改的文件：

**vue:**
```
src/pages/Home.vue                          — 页面 A（Flutter 端不涉及此文件）
src/pages/device/Dashboard.vue              — 页面 B
src/pages/device/Add.vue                    — 页面 C
src/pages/device/FindCalendar.vue           — 页面 D
src/pages/user/Profile.vue                  — 页面 E
src/pages/settings/Settings.vue             — 页面 F
src/managers/device.js                      — 设备相关 API 调用
src/managers/profile.js                     — 用户相关 API 调用
src/base/components/Layout.vue              — 全局布局组件
src/router.js                               — 路由配置
```

**flutter:**
```
lib/src/page/home.dart                      — 页面 A（首页设备列表）
lib/src/manager/device.dart                 — 设备管理器 & Device Model
lib/src/webview/webview.dart                — WebView 容器
lib/src/webview/manager.dart                — WebView 桥接管理
lib/src/base/route.dart                     — 路由配置
lib/src/manager/remote_config.dart          — H5 页面路由配置
```

**server:**
```
pronext/device/views.py                     — 设备 API 视图（app端）
pronext/device/serializers.py               — 设备序列化器
pronext/device/models.py                    — 设备模型
pronext/calendar/views.py                   — 日历 API（如有 home 接口）
```

### 6.5 设计稿资源路径

```
UI/new_ui/Calendar-Home-v2.png              — 页面 A 设计稿
UI/new_ui/Calendar-Home.png                 — 页面 B 设计稿
UI/new_ui/Home-Add-Calendar.png             — 页面 C 设计稿
UI/new_ui/Join-Family-Calendar.png          — 页面 D 设计稿
UI/new_ui/Profile.png                       — 页面 E 设计稿
UI/new_ui/Settings-v2.png                   — 页面 F 设计稿
```

---

## 7. 工期总结

| Phase | 内容 | 预估工期 |
|-------|------|---------|
| Phase 0 | 准备工作 | 0.5 天 |
| Phase 1 | 后端 API 补充 | 1 天 |
| Phase 2 | Vue H5 页面更新（6 个页面） | 3-4 天 |
| Phase 3 | Flutter 首页重构 | 2-3 天 |
| Phase 4 | 联调修缮 | 1 天 |
| Phase 5 | 测试与验收 | 1-2 天 |
| **合计** | | **8.5-11.5 天** |

> Phase 2 和 Phase 3 可部分并行，实际可压缩到 **7-9 个工作日**。

---

## 8. 已知设计问题 & 待确认项

| # | 问题 | 设计稿 | 建议 |
|---|------|--------|------|
| Q-1 | "Pronex" 是否应为 "Pronext"？ | Join-Family-Calendar.png 标题栏 | 改为 "Pronext" |
| Q-2 | "Calenda" 是否应为 "Calendar"？ | Join-Family-Calendar.png 内容 | 改为 "Calendar" |
| Q-3 | "suuport" 是否应为 "support"？ | Calendar-Home.png 底部 | 改为 "support" |
| Q-4 | "pastingthe" 应为 "pasting the"？ | Join-Family-Calendar.png 副标题 | 加空格 |
| Q-5 | Dashboard 移除了 Meal Plan 入口，是否确认？ | Calendar-Home.png | 需产品确认 |
| Q-6 | Dashboard 移除了 Share 入口（移到 Settings），是否确认？ | Calendar-Home.png + Settings-v2.png | 需产品确认 |
| Q-7 | Dashboard 移除了 Profiles 入口，是否确认？ | Calendar-Home.png | 需产品确认 |
| Q-8 | 首页右上角三点菜单的下拉内容是什么？ | Calendar-Home-v2.png | 需设计补充 |
| Q-9 | 多设备首页的 Quick Actions 是否跟随当前选中设备变化？ | Calendar-Home-v2.png | 建议跟随 |
| Q-10 | Family Sharing 的 "Share Calendar" 是复用现有 share link 流程还是新流程？ | Settings-v2.png | 建议复用 |

---

## 修订历史

| 日期 | 版本 | 变更 | 作者 |
|------|------|------|------|
| 2026-02-08 | v1.0 | 初版，基于 6 张新设计稿制定完整开发计划 | AI |
