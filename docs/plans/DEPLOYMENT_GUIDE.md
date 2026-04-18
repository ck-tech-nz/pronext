# 部署指南

## 📋 目录

- [快速开始](#-快速开始)
- [CI/CD 配置](#-cicd-配置)
- [部署流程](#-部署流程)
- [监控和调试](#-监控和调试)
- [故障排查](#-故障排查)
- [回滚策略](#-回滚策略)
- [性能优化](#-性能优化)
- [安全检查清单](#-安全检查清单)
- [最佳实践](#-最佳实践)

---

## 🚀 快速开始

### 前置条件

- ✅ GitHub Actions 已配置 Secrets
- ✅ 服务器已安装 Docker 和 Docker Compose
- ✅ 服务器已配置 Watchtower 自动更新

---

## 🔧 CI/CD 配置

### GitHub Actions Workflows

项目使用独立的 GitHub Actions workflows 进行自动化构建和部署：

```text
.github/workflows/
├── build-django.yml           # Django 服务独立构建
├── build-go-heartbeat.yml     # Go Heartbeat 服务独立构建
└── README.md                  # Workflows 详细说明文档
```

### 核心特性

#### 1. VERSION 文件自动生成

每次构建都会生成 VERSION 文件，包含：

```text
env/test:
abc1234
 - build:01-11-2025 20:30:45
```

#### 2. 基于分支的环境

- `env/test` → 构建测试镜像
- `env/prod` → 构建生产镜像

#### 3. 智能路径检测

- Django 代码变更 → 只构建 Django 镜像
- Go 代码变更 → 只构建 Go 镜像
- 同时变更 → 并行构建两个镜像

#### 4. 独立的构建通知

- `Django [test/prod] build success/FAILED`
- `Go-Heartbeat [test/prod] build success/FAILED`

### 镜像命名规范

| 环境 | Django 镜像 | Go Heartbeat 镜像 |
|------|-------------|------------------|
| 测试 | `pronext-test` | `go-heartbeat-test` |
| 生产 | `pronext` | `go-heartbeat` |

每个镜像都有两个标签：

- `latest` - 始终指向最新版本
- `<commit-hash>` - 特定提交版本（用于回滚）

### GitHub Secrets 配置

在 GitHub 仓库设置中添加：

```text
Settings → Secrets and variables → Actions → New repository secret
```

必需的 Secret：

- Name: `CODING_ARTIFACT_REGISTRY_PRIVATE_KEY`
- Value: `<your-coding-registry-password>`

### 开发工作流

```bash
# 1. 本地开发
git checkout develop
# ... 开发代码 ...
git commit -m "feat: new feature"

# 2. 部署到测试
git checkout env/test
git merge develop
git push origin env/test

# 3. 自动发生：
# ✅ GitHub Actions 检测变更
# ✅ 构建对应服务的镜像
# ✅ 推送到 Registry
# ✅ Watchtower 自动更新容器
# ✅ 收到手机通知

# 4. 测试通过后部署生产
git checkout env/prod
git merge env/test
git push origin env/prod
```

### CI/CD 性能对比

| 特性 | 旧方案 | 新方案 |
|------|--------|--------|
| 构建触发 | 所有变更都构建全部 | 只构建变更的服务 |
| 构建时间 | 总是构建两个镜像 | 平均快 50% |
| 失败影响 | 一个失败全失败 | 互不影响 |
| 通知粒度 | 统一通知 | 独立通知 |
| 可维护性 | 耦合在一起 | 职责清晰 |
| VERSION 文件 | ✅ | ✅ 两个服务独立 |
| 分支策略 | 只支持 env/prod | 支持 test 和 prod |

---

## 📋 部署流程

### 1️⃣ 首次部署

#### 测试环境

```bash
# 1. SSH 登录测试服务器
ssh user@test-server

# 2. 克隆仓库
git clone <repository-url>
cd server

# 3. 切换到测试分支
git checkout env/test

# 4. 配置环境变量
cp .env.example .env
vim .env  # 编辑配置

# 5. 登录 Docker Registry
docker login -u imgs-1708918898742 \
  -p <CODING_ARTIFACT_REGISTRY_PRIVATE_KEY> \
  realck-docker.pkg.coding.net

# 6. 拉取镜像
docker-compose pull

# 7. 启动服务
docker-compose up -d

# 8. 检查服务状态
docker-compose ps
docker-compose logs -f
```

#### 生产环境

```bash
# 1. SSH 登录生产服务器
ssh user@prod-server

# 2. 克隆仓库
git clone <repository-url>
cd server

# 3. 切换到生产分支
git checkout env/prod

# 4. 使用生产配置
cp .env.example .env
vim .env  # 配置生产环境变量

# 重要：生产环境设置
# PAD_API_CHECK_SIGN=true
# DEBUG=False

# 5. 使用生产 docker-compose
docker-compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# 6. 验证部署
curl https://api.pronextusa.com/health
curl http://localhost:8080/health  # Go 服务
```

---

### 2️⃣ 日常部署流程

得益于 **GitHub Actions + Watchtower** 自动化，日常部署非常简单：

#### 部署到测试环境

```bash
# 本地开发完成后
git checkout env/test
git merge develop  # 或者 cherry-pick 特定提交
git push origin env/test

# 🎉 完成！接下来自动发生：
# 1. GitHub Actions 检测到 push
# 2. 根据文件变更决定构建 Django 或 Go 或两者
# 3. 构建并推送 Docker 镜像
# 4. Watchtower 在 5 分钟内检测到新镜像
# 5. 自动拉取并重启容器
# 6. 收到 Bark 通知
```

#### 部署到生产环境

```bash
# 测试通过后
git checkout env/prod
git merge env/test
git push origin env/prod

# 🎉 同样是全自动！
```

---

### 3️⃣ 手动更新（如果需要）

如果 Watchtower 未自动更新，可以手动操作：

```bash
# SSH 到服务器
ssh user@server

cd server

# 拉取最新镜像
docker-compose pull

# 重启服务
docker-compose up -d

# 清理旧镜像（可选）
docker image prune -a -f
```

---

## 🔍 监控和调试

### 查看日志

```bash
# 所有服务日志
docker-compose logs -f

# 仅 Django 日志
docker-compose logs -f api

# 仅 Go Heartbeat 日志
docker-compose logs -f heartbeat

# 仅 Redis 日志
docker-compose logs -f redis

# 最近 100 行
docker-compose logs --tail=100
```

### 检查服务状态

```bash
# 容器状态
docker-compose ps

# Django 健康检查
curl http://localhost:8888/admin/

# Go Heartbeat 健康检查
curl http://localhost:8080/health

# Redis 连接测试
docker exec -it redis redis-cli -a JWvyFWcXRA9fDFY9KmDcWtAxTCyTydAM ping
```

### 进入容器

```bash
# Django 容器
docker exec -it pronext bash
python manage.py shell

# Go Heartbeat 容器
docker exec -it heartbeat sh

# Redis 容器
docker exec -it redis redis-cli -a JWvyFWcXRA9fDFY9KmDcWtAxTCyTydAM
```

---

## 🆘 故障排查

### 问题 1：容器启动失败

```bash
# 查看详细错误
docker-compose logs api
docker-compose logs heartbeat

# 常见原因：
# - 环境变量配置错误
# - Redis 连接失败
# - 端口冲突
```

### 问题 2：Watchtower 未自动更新

```bash
# 查看 Watchtower 日志
docker logs watchtower

# 手动触发 Watchtower
docker restart watchtower

# 验证 Watchtower 配置
docker inspect watchtower
```

### 问题 3：镜像拉取失败

```bash
# 重新登录 Registry
docker logout realck-docker.pkg.coding.net
docker login -u imgs-1708918898742 \
  -p <password> \
  realck-docker.pkg.coding.net

# 手动拉取测试
docker pull realck-docker.pkg.coding.net/cktech/images/pronext-test
```

### 问题 4：Redis 连接失败

```bash
# 检查 Redis 是否运行
docker-compose ps redis

# 测试连接
docker exec -it heartbeat sh -c 'nc -zv redis 6379'

# 检查密码
echo $DJANGO_REDIS
```

### 问题 5：Go 服务启动失败

```bash
# 查看 Go 服务日志
docker-compose logs heartbeat

# 常见错误：
# - "DJANGO_REDIS environment variable is required"
#   解决：检查 .env 文件中的 DJANGO_REDIS 配置
#
# - "failed to connect to Redis"
#   解决：确保 Redis 容器先启动，检查密码
```

---

## 🔄 回滚策略

### 方法 1：使用特定 commit 的镜像

```bash
# 查看可用的镜像标签
docker images | grep pronext
docker images | grep go-heartbeat

# 回滚到特定版本
docker tag realck-docker.pkg.coding.net/cktech/images/pronext-test:abc1234 \
  realck-docker.pkg.coding.net/cktech/images/pronext-test:latest

docker-compose up -d
```

### 方法 2：Git 回滚后重新构建

```bash
# 本地回滚到之前的提交
git checkout env/test
git revert <commit-hash>
git push origin env/test

# GitHub Actions 会自动构建旧版本的镜像
```

### 方法 3：手动回滚分支

```bash
# 强制回滚分支（谨慎使用）
git checkout env/test
git reset --hard <old-commit-hash>
git push -f origin env/test
```

---

## 📊 性能优化

### 1. 调整 Docker Compose 资源限制

```yaml
services:
  api:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '1'
          memory: 1G
```

### 2. 配置 Watchtower 检查间隔

```yaml
watchtower:
  command: --interval 300  # 5 分钟检查一次
```

### 3. Go 服务性能调优

Go 服务默认配置已经很高效，如需要可以调整：

```yaml
heartbeat:
  environment:
    - GOMAXPROCS=4  # 调整 Go 并发数
```

---

## 🔐 安全检查清单

### 生产环境部署前

- [ ] `DEBUG=False`
- [ ] `PAD_API_CHECK_SIGN=true`
- [ ] 更换默认的 `SIGNING_KEY`
- [ ] 更换默认的 Redis 密码
- [ ] 配置 HTTPS (Traefik TLS)
- [ ] 限制 SSH 访问
- [ ] 配置防火墙规则
- [ ] 定期备份数据库
- [ ] 配置日志轮转

---

## 📞 支持

遇到问题？

1. 查看 [.github/workflows/README.md](.github/workflows/README.md)
2. 查看 [go-heartbeat/README.md](../go-heartbeat/README.md)
3. 检查 GitHub Actions 构建日志
4. 查看服务器容器日志

---

## 🎯 最佳实践

1. **始终在测试环境验证**：先部署到 `env/test`，测试通过后再到 `env/prod`
2. **监控通知**：关注 Bark 通知，及时响应构建失败
3. **定期更新**：保持 Docker 镜像和依赖包的更新
4. **备份策略**：定期备份数据库和重要配置
5. **文档更新**：重大变更后更新相关文档
6. **版本记录**：每个版本都保留对应的 commit hash 标签，便于追踪和回滚

---

## 🆕 版本历史

查看每个版本的 VERSION 文件：

```bash
# Django 服务
docker exec -it pronext cat VERSION

# Go Heartbeat 服务
docker exec -it heartbeat cat VERSION
```

输出示例：

```text
env/test:
abc1234
 - build:01-11-2025 20:30:45
```
