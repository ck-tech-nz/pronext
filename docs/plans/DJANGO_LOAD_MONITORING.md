# Django 负载监控工具使用指南

## 概述

Django 负载监控工具是一套完整的脚本集，用于监控 Django/Gunicorn 服务的运行状态，分析性能指标，并自动推荐最优的 Gunicorn 启动参数。

### 工具组成

1. **`check_django_load.sh`** - 主监控脚本，收集指标并生成报告
2. **`quick_check.sh`** - 快速健康检查脚本
3. **`analyze_django_load.py`** - Python 分析工具（可选）

### 主要功能

- ✅ 实时收集系统性能指标
- ✅ 监控 Gunicorn worker 状态
- ✅ 分析网络连接情况
- ✅ 测试响应时间和成功率
- ✅ 自动计算推荐配置
- ✅ 生成 JSON 格式详细报告
- ✅ 提供人类可读的总结

---

## 快速开始

### 前置要求

```bash
# 必需工具
brew install jq bc      # macOS
# 或
apt-get install jq bc   # Linux

# 可选工具（用于更准确的 backlog 检测）
brew install iproute2mac  # macOS (ss 命令)
```

### 运行主监控脚本

```bash
cd /path/to/server

# 基本使用（使用默认端口 8888）
./scripts/check_django_load.sh

# 指定端口
DJANGO_PORT=8000 ./scripts/check_django_load.sh

# 指定输出文件
OUTPUT_FILE=/var/log/django_report.json ./scripts/check_django_load.sh
```

### 快速检查

```bash
# 快速健康检查（30秒内完成）
./scripts/quick_check.sh

# 指定端口
DJANGO_PORT=8000 ./scripts/quick_check.sh
```

---

## 详细使用说明

### 1. 主监控脚本 (`check_django_load.sh`)

#### 功能说明

主监控脚本会执行以下检查：

1. **系统指标**
   - CPU 核心数
   - 系统负载（Load Average）
   - 总内存容量

2. **Gunicorn 进程指标**
   - Master 进程状态
   - Worker 进程数量
   - 每个 Worker 的 CPU 和内存使用
   - 总体资源消耗

3. **网络指标**
   - 当前活跃连接数（ESTABLISHED）
   - TIME_WAIT 连接数
   - Backlog 队列长度

4. **性能指标**
   - HTTP 响应时间（P50/P95/P99）
   - 请求成功率
   - 估算的每秒请求数（RPS）

5. **推荐配置**
   - Worker 数量
   - Worker 连接数
   - Max-requests
   - 超时时间
   - Backlog 大小

#### 输出说明

脚本会输出两部分内容：

**1. 控制台输出（人类可读）**
```
========================================
  Report Summary
========================================

Status: HEALTHY

Current Configuration:
  Workers: 2
  Total CPU: 25.5%
  Total Memory: 320 MB
  Active Connections: 45

Performance:
  Est. Requests/sec: 12.5
  Mean Response Time: 125.3 ms
  P95 Response Time: 245.8 ms
  Success Rate: 100.00%

Recommended Configuration:
  workers: 2
  worker_connections: 200
  max_requests: 50000
  ...
```

**2. JSON 报告文件**
- 默认位置：`/tmp/django_load_report.json`
- 包含所有详细数据，可用于：
  - 历史对比
  - 自动化监控
  - 数据分析

#### 环境变量

```bash
DJANGO_PORT=8888              # Django 服务端口（默认：8888）
OUTPUT_FILE=/path/to/file.json # 输出文件路径（默认：/tmp/django_load_report.json）
```

### 2. 快速检查脚本 (`quick_check.sh`)

快速检查脚本提供 30 秒内的快速健康状态概览：

```bash
Django Quick Health Check

✓ Gunicorn is running
  Workers: 2
  Total CPU: 25.5%
  Total Memory: 320 MB
  Active Connections: 45
  Response: ✓ 302 (125ms)

✓ System is healthy
```

**适用场景**：
- 日常快速检查
- CI/CD 健康检查
- 告警验证

### 3. Python 分析工具 (`analyze_django_load.py`)

#### 单个报告分析

```bash
python3 scripts/analyze_django_load.py /tmp/django_load_report.json
```

**输出**：
- 详细的格式化报告
- 效率指标（每 worker RPS、CPU 效率等）
- 深度分析

#### 对比两个报告

```bash
python3 scripts/analyze_django_load.py \
    /tmp/report_20241101.json \
    /tmp/report_20241102.json
```

**用途**：
- 参数调整前后对比
- 负载增长趋势分析
- 性能优化效果验证

---

## 指标解读

### 系统指标

| 指标 | 正常范围 | 警告 | 严重 |
|------|---------|------|------|
| **Load Average** | < CPU核心数 | > CPU核心数×1.5 | > CPU核心数×2 |
| **Total CPU** | < 60% | 60-80% | > 80% |
| **Total Memory** | < 50% 可用内存 | 50-80% | > 80% |

### Gunicorn 指标

| 指标 | 说明 | 健康标准 |
|------|------|---------|
| **Worker Count** | 当前 worker 数量 | 根据负载自动推荐 |
| **Avg Worker CPU** | 单个 worker 平均 CPU | < 15% |
| **Avg Worker Memory** | 单个 worker 平均内存 | < 200MB |

### 性能指标

| 指标 | 说明 | 健康标准 |
|------|------|---------|
| **Est. RPS** | 估算的每秒请求数 | 根据业务需求 |
| **Mean RT** | 平均响应时间 | < 500ms |
| **P95 RT** | 95% 请求的响应时间 | < 1s |
| **Success Rate** | 请求成功率 | > 99% |

### 网络指标

| 指标 | 说明 | 健康标准 |
|------|------|---------|
| **Established** | 活跃连接数 | < worker_connections × workers |
| **Backlog** | 等待队列长度 | < backlog × 0.8 |

---

## 推荐算法说明

### Worker 数量推荐

```
基于 RPS：
  - RPS < 20: 保持当前或略减
  - RPS 20-50: 2-4 workers
  - RPS 50-100: 4-8 workers
  - RPS > 100: 根据 CPU 和负载计算

基于 CPU：
  - CPU < 60%: 保持当前
  - CPU 60-80%: 增加 50%
  - CPU > 80%: 增加到 CPU核心数×2
```

### Worker Connections 推荐

```
基于当前连接数：
  - 连接数 × 2（提供缓冲）
  - 最小 100，最大 2000
  - 建议 200-500（低负载）或 500-1000（高负载）
```

### Max-requests 推荐

```
基于负载：
  - 低负载（< 20 req/s）: 50000
  - 中负载（20-100 req/s）: 20000
  - 高负载（> 100 req/s）: 10000
```

### Timeout 推荐

```
基于 P95 响应时间：
  - P95 × 4（提供充足缓冲）
  - 最小 30s，最大 300s
  - 建议 60s（低频）或 30s（高频）
```

---

## 使用场景

### 场景 1：初始部署

```bash
# 1. 部署后运行检查
./scripts/check_django_load.sh

# 2. 查看推荐配置
cat /tmp/django_load_report.json | jq '.recommendations.recommended_config'

# 3. 更新启动参数
# 根据推荐修改 entrypoint.sh 或 docker-compose.yml
```

### 场景 2：定期监控

```bash
# 创建定时任务（crontab）
# 每小时检查一次
0 * * * * /path/to/scripts/check_django_load.sh >> /var/log/django_monitor.log 2>&1

# 每天保存一次报告
0 0 * * * cp /tmp/django_load_report.json /var/log/django_reports/report_$(date +\%Y\%m\%d).json
```

### 场景 3：扩容决策

```bash
# 1. 运行检查
./scripts/check_django_load.sh

# 2. 查看状态
cat /tmp/django_load_report.json | jq '.recommendations.status'

# 3. 如果状态为 "warning" 或 "critical"
#    查看推荐的 worker 数量
cat /tmp/django_load_report.json | jq '.recommendations.recommended_config.workers'

# 4. 对比历史数据
python3 scripts/analyze_django_load.py \
    /var/log/django_reports/report_20241101.json \
    /tmp/django_load_report.json
```

### 场景 4：故障排查

```bash
# 1. 快速检查（30秒）
./scripts/quick_check.sh

# 2. 如果发现问题，运行详细检查
./scripts/check_django_load.sh

# 3. 查看详细报告
python3 scripts/analyze_django_load.py /tmp/django_load_report.json

# 4. 检查警告信息
cat /tmp/django_load_report.json | jq '.recommendations.warnings'
```

---

## 监控最佳实践

### 1. 定期检查频率

| 场景 | 建议频率 |
|------|---------|
| **生产环境（稳定）** | 每天 1 次 |
| **生产环境（增长期）** | 每小时 1 次 |
| **测试环境** | 每周 1 次 |
| **故障排查** | 随时 |

### 2. 告警阈值

建议设置以下告警：

```bash
# 检查脚本添加到 crontab
0 * * * * /path/to/scripts/check_django_load.sh

# 监控脚本（检测告警）
#!/bin/bash
REPORT="/tmp/django_load_report.json"
STATUS=$(jq -r '.recommendations.status' "$REPORT")

if [ "$STATUS" = "critical" ]; then
    # 发送告警（邮件、Slack等）
    echo "CRITICAL: Django load status is critical" | mail -s "Alert" admin@example.com
fi
```

### 3. 历史数据保存

```bash
# 创建保存目录
mkdir -p /var/log/django_reports

# 保存脚本（添加到 crontab）
#!/bin/bash
REPORT_DIR="/var/log/django_reports"
DATE=$(date +%Y%m%d_%H%M%S)
cp /tmp/django_load_report.json "$REPORT_DIR/report_${DATE}.json

# 清理旧文件（保留 30 天）
find "$REPORT_DIR" -name "report_*.json" -mtime +30 -delete
```

---

## 容器环境使用

### 在 Docker 容器中运行

如果 Django 运行在 Docker 容器中：

```bash
# 方式 1：在容器内运行（推荐）
docker exec -it <container_name> /bin/bash
cd /app
./scripts/check_django_load.sh

# 方式 2：从宿主机运行
docker exec <container_name> /app/scripts/check_django_load.sh

# 方式 3：如果进程检测失败，使用诊断脚本
docker exec -it <container_name> /bin/bash
./scripts/check_django_load_container.sh
```

### 容器环境特殊说明

在容器中，进程名称可能不同：
- Gunicorn 可能作为 PID 1 运行（Docker 主进程）
- 进程名可能是 `python` 而不是 `gunicorn`
- 脚本会自动尝试多种检测方式

如果仍然检测失败，可以手动指定端口：
```bash
DJANGO_PORT=8888 ./scripts/check_django_load.sh
```

## 故障排查指南

### 问题 1：脚本无法运行

**症状**：`command not found: jq` 或 `command not found: bc`

**解决**：
```bash
# macOS
brew install jq bc

# Linux (Debian/Ubuntu)
apt-get update && apt-get install jq bc

# Linux (RHEL/CentOS)
yum install jq bc
```

### 问题 2：Gunicorn 进程未找到

**症状**：`Error: Gunicorn master process not found!`

**解决**：
```bash
# 检查 Gunicorn 是否运行
ps aux | grep gunicorn

# 检查进程名称是否正确
# 如果进程名不同，需要修改脚本中的 grep 模式
```

### 问题 3：连接数统计不准确

**症状**：连接数显示为 0 但实际有连接

**解决**：
```bash
# 确认端口号正确
DJANGO_PORT=8888 ./scripts/check_django_load.sh

# 手动检查连接
netstat -an | grep :8888 | grep ESTABLISHED
```

### 问题 4：响应时间测试失败

**症状**：所有响应测试都失败（HTTP 000）

**解决**：
```bash
# 检查 Django 是否可访问
curl -v http://localhost:8888/admin/

# 检查防火墙
# 确认 /admin/ 路径存在（或修改脚本中的测试 URL）
```

### 问题 5：推荐参数不合理

**症状**：推荐的 worker 数量过高或过低

**解决**：
```bash
# 查看详细推理
cat /tmp/django_load_report.json | jq '.recommendations.reasoning'

# 手动验证估算的 RPS
# 如果估算不准，可以调整脚本中的计算逻辑
```

---

## 示例输出

### 正常情况（Healthy）

```
========================================
  Report Summary
========================================

Status: HEALTHY

Current Configuration:
  Workers: 2
  Total CPU: 25.5%
  Total Memory: 320 MB
  Active Connections: 45

Performance:
  Est. Requests/sec: 12.5
  Mean Response Time: 125.3 ms
  P95 Response Time: 245.8 ms
  Success Rate: 100.00%

Recommended Configuration:
  workers: 2
  worker_connections: 200
  max_requests: 50000
  max_requests_jitter: 5000
  backlog: 512
  timeout: 60
  keep_alive: 5
  graceful_timeout: 30
```

### 警告情况（Warning）

```
Status: WARNING

⚠️ Warnings:
  ⚠️  High CPU usage: 85.2%
  ⚠️  High response time: 1250.5ms

Recommended Configuration:
  workers: 4
  worker_connections: 300
  ...
```

### 严重情况（Critical）

```
Status: CRITICAL

⚠️ Warnings:
  ⚠️  Low success rate: 92.5%
  ⚠️  High CPU usage: 95.8%
  ⚠️  High memory usage risk
```

---

## 集成到 CI/CD

### GitHub Actions 示例

```yaml
name: Django Health Check

on:
  schedule:
    - cron: '0 * * * *'  # 每小时
  workflow_dispatch:

jobs:
  health-check:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v2

      - name: Run health check
        run: ./scripts/check_django_load.sh

      - name: Check status
        run: |
          STATUS=$(jq -r '.recommendations.status' /tmp/django_load_report.json)
          if [ "$STATUS" = "critical" ]; then
            echo "CRITICAL status detected!"
            exit 1
          fi

      - name: Upload report
        uses: actions/upload-artifact@v2
        with:
          name: django-report
          path: /tmp/django_load_report.json
```

---

## 常见问题（FAQ）

### Q: 脚本需要多长时间运行？

A: 通常 10-30 秒，取决于网络延迟和系统负载。

### Q: 推荐的参数一定准确吗？

A: 推荐基于当前负载估算，建议：
- 作为起点，逐步调整
- 定期重新运行检查
- 根据实际情况微调

### Q: 可以自动化调整参数吗？

A: 可以，但不推荐完全自动化。建议：
- 脚本提供建议
- 人工审核后再应用
- 测试验证后再上线

### Q: 历史数据如何分析？

A: 使用 `analyze_django_load.py` 对比多个报告：
```bash
python3 scripts/analyze_django_load.py \
    report_week1.json \
    report_week2.json
```

---

## 相关文档

- [Gunicorn 官方文档](https://docs.gunicorn.org/)
- [Django 部署指南](./DEPLOYMENT_GUIDE.md)
- [Go Heartbeat 测试文档](../go-heartbeat/TESTING.md)

---

## 更新日志

- **2025-11-01**: 初始版本发布
  - 基本监控功能
  - 自动推荐算法
  - JSON 报告格式

---

## 贡献

如有问题或建议，请提交 Issue 或 Pull Request。
