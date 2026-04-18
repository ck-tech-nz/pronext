# Heartbeat Service Migration Guide

## 📋 目录

<!-- TOC -->

- [Heartbeat Service Migration Guide](#heartbeat-service-migration-guide)
    - [📋 目录](#-%E7%9B%AE%E5%BD%95)
    - [Overview](#overview)
    - [📦 Go Heartbeat 实现原理](#-go-heartbeat-%E5%AE%9E%E7%8E%B0%E5%8E%9F%E7%90%86)
        - [依赖库说明](#%E4%BE%9D%E8%B5%96%E5%BA%93%E8%AF%B4%E6%98%8E)
    - [🏗️ 文件结构和职责](#-%E6%96%87%E4%BB%B6%E7%BB%93%E6%9E%84%E5%92%8C%E8%81%8C%E8%B4%A3)
        - [main.go - 程序入口和配置管理配置管理](#maingo---%E7%A8%8B%E5%BA%8F%E5%85%A5%E5%8F%A3%E5%92%8C%E9%85%8D%E7%BD%AE%E7%AE%A1%E7%90%86%E9%85%8D%E7%BD%AE%E7%AE%A1%E7%90%86)
        - [auth.go - Pad 设备签名认证签名认证](#authgo---pad-%E8%AE%BE%E5%A4%87%E7%AD%BE%E5%90%8D%E8%AE%A4%E8%AF%81%E7%AD%BE%E5%90%8D%E8%AE%A4%E8%AF%81)
        - [jwt.go - JWT Token 验证 en 验证](#jwtgo---jwt-token-%E9%AA%8C%E8%AF%81-en-%E9%AA%8C%E8%AF%81)
        - [cache.go - 缓存抽象层存抽象层](#cachego---%E7%BC%93%E5%AD%98%E6%8A%BD%E8%B1%A1%E5%B1%82%E5%AD%98%E6%8A%BD%E8%B1%A1%E5%B1%82)
        - [beat.go - Beat 状态管理状态管理](#beatgo---beat-%E7%8A%B6%E6%80%81%E7%AE%A1%E7%90%86%E7%8A%B6%E6%80%81%E7%AE%A1%E7%90%86)
        - [handlers.go - HTTP 请求处理器求处理器](#handlersgo---http-%E8%AF%B7%E6%B1%82%E5%A4%84%E7%90%86%E5%99%A8%E6%B1%82%E5%A4%84%E7%90%86%E5%99%A8)
    - [🔄 完整工作流程](#-%E5%AE%8C%E6%95%B4%E5%B7%A5%E4%BD%9C%E6%B5%81%E7%A8%8B)
    - [💡 关键设计亮点](#-%E5%85%B3%E9%94%AE%E8%AE%BE%E8%AE%A1%E4%BA%AE%E7%82%B9)
        - [中间件模式 Middleware Pattern](#%E4%B8%AD%E9%97%B4%E4%BB%B6%E6%A8%A1%E5%BC%8F-middleware-pattern)
        - [接口抽象 Interface Abstraction](#%E6%8E%A5%E5%8F%A3%E6%8A%BD%E8%B1%A1-interface-abstraction)
        - [Context 传递 Context Propagation](#context-%E4%BC%A0%E9%80%92-context-propagation)
        - [配置管理](#%E9%85%8D%E7%BD%AE%E7%AE%A1%E7%90%86)
        - [与 Django 兼容](#%E4%B8%8E-django-%E5%85%BC%E5%AE%B9)
    - [🎯 功能实现对照表](#-%E5%8A%9F%E8%83%BD%E5%AE%9E%E7%8E%B0%E5%AF%B9%E7%85%A7%E8%A1%A8)
    - [Changes Made](#changes-made)
        - [New Go Service go-heartbeat/](#new-go-service-go-heartbeat)
        - [Updated Beat Model pronext/common/models.py](#updated-beat-model-pronextcommonmodelspy)
        - [Django Integration](#django-integration)
        - [Docker Configuration](#docker-configuration)
    - [Deployment Steps](#deployment-steps)
        - [Step 1: Environment Configuration](#step-1-environment-configuration)
        - [Step 2: Build and Deploy](#step-2-build-and-deploy)
        - [Step 3: Verify Integration](#step-3-verify-integration)
        - [Step 4: Update Client Applications Optional](#step-4-update-client-applications-optional)
    - [Rollback Plan](#rollback-plan)
        - [Option 1: Disable Go Service Mode](#option-1-disable-go-service-mode)
        - [Option 2: Full Rollback](#option-2-full-rollback)
    - [Monitoring](#monitoring)
        - [Health Checks](#health-checks)
        - [Online Device Count](#online-device-count)
    - [Performance Comparison](#performance-comparison)
        - [Before Django + Redis](#before-django--redis)
        - [After Go Service + Memory Cache](#after-go-service--memory-cache)
    - [Redis Cache Management](#redis-cache-management)
        - [Understanding Redis Cache Impact](#understanding-redis-cache-impact)
        - [Data Stored in Redis](#data-stored-in-redis)
        - [⚠️ Critical Warning: Impact of Clearing Redis Cache](#-critical-warning-impact-of-clearing-redis-cache)
            - [Immediate Impact 0-5 seconds](#immediate-impact-0-5-seconds)
            - [Short-term Impact 5-60 seconds](#short-term-impact-5-60-seconds)
            - [Permanent Data Loss](#permanent-data-loss)
        - [Safe Cache Clearing Procedures](#safe-cache-clearing-procedures)
            - [Option 1: Selective Clearing Recommended](#option-1-selective-clearing-recommended)
            - [Option 2: Full Cache Clear Emergency Only](#option-2-full-cache-clear-emergency-only)
            - [Option 3: Memory Optimization No Data Loss](#option-3-memory-optimization-no-data-loss)
        - [Pre-Deployment Cache Clearing](#pre-deployment-cache-clearing)
        - [Monitoring After Cache Clear](#monitoring-after-cache-clear)
        - [Decision Matrix: Should I Clear Redis Cache?](#decision-matrix-should-i-clear-redis-cache)
        - [Recovery Checklist](#recovery-checklist)
    - [Known Limitations](#known-limitations)
    - [Troubleshooting](#troubleshooting)
        - [Issue: "Failed to update Go heartbeat service"](#issue-failed-to-update-go-heartbeat-service)
        - [Issue: "Invalid token" errors](#issue-invalid-token-errors)
        - [Issue: Devices not appearing online](#issue-devices-not-appearing-online)
    - [Support](#support)
    - [Future Enhancements](#future-enhancements)

<!-- /TOC -->

## Overview

This document describes the migration from Django-based heartbeat handling to the new Go-based heartbeat service for improved performance and scalability.

---

## 📦 Go Heartbeat 实现原理

### 依赖库说明

Go Heartbeat 服务使用的核心依赖（参见 `go-heartbeat/go.mod`）：

```go
require (
	github.com/gorilla/mux v1.8.1
	github.com/joho/godotenv v1.5.1
	github.com/patrickmn/go-cache v2.1.0+incompatible
	github.com/redis/go-redis/v9 v9.7.0
	github.com/golang-jwt/jwt/v5 v5.3.0
)
```

**依赖说明**：

- **gorilla/mux**: HTTP 路由器，用于处理 URL 路由
- **joho/godotenv**: 加载.env 环境变量文件
- **redis/go-redis**: Redis 客户端，与 Django 共享缓存（**必需**，不再支持内存缓存降级）
- **golang-jwt/jwt**: JWT token 验证库，实现独立的 token 验证

## 🏗️ 文件结构和职责

### main.go - 程序入口和配置管理配置管理

参见 `go-heartbeat/main.go`

```go
func init() {
	// Load .env file from parent directory (if exists)
	envPath := filepath.Join("..", ".env")
	if err := godotenv.Load(envPath); err != nil {
		log.Printf("Warning: .env file not found, using environment variables")
	}

	// Load configuration
	config = &Config{
		Port:             getEnv("PORT", "8080"),
		JWTSecret:        getEnv("SIGNING_KEY", "..."),
		DjangoBackendURL: getEnv("DJANGO_BACKEND_URL", "http://localhost:8000"),
		DjangoRedis:      getEnv("DJANGO_REDIS", ""),
		PadAPICheckSign:  getEnvBool("PAD_API_CHECK_SIGN", false),
	}

	// Initialize cache backend (Redis or in-memory)
	if err := InitCache(config.DjangoRedis); err != nil {
		log.Fatalf("Failed to initialize cache: %v", err)
	}
}
```

**职责**：

- 加载环境变量配置
- 初始化缓存后端（Redis 或内存）
- 设置 HTTP 路由
- 启动 HTTP 服务器

### auth.go - Pad 设备签名认证签名认证

参见 `go-heartbeat/auth.go`

```go
// padAuthMiddleware validates pad signature and attaches Pad to context
func padAuthMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		signature := r.Header.Get("Signature")
		timestamp := r.Header.Get("Timestamp")

		// Decrypt signature
		plaintext, err := decryptPadSign(signature)
		if err != nil {
			http.Error(w, `{"error": "Invalid signature"}`, http.StatusUnauthorized)
			return
		}

		// Parse signature: app_build_num|mac|sn|system_version|time
		parts := strings.Split(plaintext, "|")
		// ... 解析各个字段 ...

		// Verify timestamp matches
		if time != timestamp {
			http.Error(w, `{"error": "Invalid signature"}`, http.StatusUnauthorized)
			return
		}

		// Validate device SN if check is enabled
		if config.PadAPICheckSign && !checkDeviceSN(sn) {
			http.Error(w, `{"error": "Invalid signature"}`, http.StatusUnauthorized)
			return
		}

		// Create Pad object and add to context
		pad := &Pad{AppBuildNum: appBuildNum, MAC: mac, SN: sn, SystemVersion: systemVersion}
		ctx := context.WithValue(r.Context(), padContextKey, pad)
		next.ServeHTTP(w, r.WithContext(ctx))
	}
}
```

**职责**：

- 验证 Pad 设备的加密签名（AES-CBC 解密）
- 检查设备序列号的合法性
- 将认证通过的设备信息存入 context

### jwt.go - JWT Token 验证 en 验证

参见 `go-heartbeat/jwt.go`

```go
// ValidateJWTToken validates a JWT token and extracts user information
func ValidateJWTToken(tokenString string) (*JWTUser, error) {
	// Parse the token
	token, err := jwt.ParseWithClaims(tokenString, &JWTClaims{}, func(token *jwt.Token) (interface{}, error) {
		// Verify the signing method
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method")
		}
		return []byte(config.JWTSecret), nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to parse token: %w", err)
	}

	// Extract claims
	if claims, ok := token.Claims.(*JWTClaims); ok && token.Valid {
		return &JWTUser{
			ID:        claims.UserID,
			RelUserID: claims.RelUserID,
			Exp:       claims.ExpiresAt.Unix(),
		}, nil
	}

	return nil, fmt.Errorf("invalid token claims")
}
```

**职责**：

- 验证 JWT token 的有效性
- 提取用户 ID 和过期时间
- 判断 token 是否需要刷新

### cache.go - 缓存抽象层存抽象层

参见 `go-heartbeat/cache.go`

```go
// CacheBackend defines the interface for cache operations
type CacheBackend interface {
	Get(key string) (interface{}, bool)
	Set(key string, value interface{}, expiration time.Duration) error
	Delete(key string) error
}

// RedisCacheBackend implements CacheBackend using Redis
type RedisCacheBackend struct {
	client *redis.Client
	ctx    context.Context
}

func NewRedisCacheBackend(redisURL string) (*RedisCacheBackend, error) {
	opt, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse Redis URL: %w", err)
	}

	client := redis.NewClient(opt)
	ctx := context.Background()

	// Test connection
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to Redis: %w", err)
	}

	return &RedisCacheBackend{client: client, ctx: ctx}, nil
}

// InitCache initializes the cache backend based on configuration
// Redis is required for production to share cache with Django
func InitCache(redisURL string) error {
	if redisURL == "" {
		return fmt.Errorf("DJANGO_REDIS environment variable is required")
	}

	backend, err := NewRedisCacheBackend(redisURL)
	if err != nil {
		return fmt.Errorf("failed to connect to Redis: %w", err)
	}

	cacheBackend = backend
	return nil
}
```

**职责**：

- 定义缓存接口（仅支持 Redis 实现）
- 提供统一的缓存操作 API
- **Redis 是必需的**，启动时如果连接失败会退出程序

### beat.go - Beat 状态管理状态管理

参见 `go-heartbeat/beat.go`

```go
// GetBeat retrieves the Beat object for a device
func GetBeat(deviceID, relUserID int64, checkSyncCalendar bool) *Beat {
	key := getBeatCacheKey(deviceID)

	// Try to get from cache
	if cached, found := CacheGet(key); found {
		if beat, ok := cached.(*Beat); ok {
			// Make a copy of the beat to return
			result := &Beat{
				EventCate:   beat.EventCate,
				Event:       beat.Event,
				RemindEvent: beat.RemindEvent,
				ChoreCate:   beat.ChoreCate,
				Chore:       beat.Chore,
				Photo:       beat.Photo,
				TodoList:    beat.TodoList,
				Settings:    beat.Settings,
			}

			// Check sync calendar if requested
			if checkSyncCalendar {
				syncKey := getSyncCalendarKey(deviceID, relUserID)
				if _, found := CacheGet(syncKey); found {
					result.SyncCalendar = true
					CacheDelete(syncKey)
				}
			}

			// Clear the flags in cache for next heartbeat
			CacheSet(key, &Beat{}, BeatExpire)
			return result
		}
	}

	// Return a new empty Beat
	return &Beat{}
}
```

**职责**：

- 管理 Beat 同步标志位（事件、待办、照片等）
- 追踪设备在线状态
- 使用 Redis SET 操作管理在线设备集合

### handlers.go - HTTP 请求处理器求处理器

参见 `go-heartbeat/handlers.go`

```go
// heartbeatHandler handles the pad heartbeat endpoint
func heartbeatHandler(w http.ResponseWriter, r *http.Request) {
	// Get pad from context (already authenticated via padAuthMiddleware)
	pad, err := getPadFromContext(r.Context())
	if err != nil {
		http.Error(w, `{"error": "Unauthorized"}`, http.StatusUnauthorized)
		return
	}

	// Extract and validate JWT token
	tokenString, err := ExtractJWTFromRequest(r)
	user, err := ValidateJWTToken(tokenString)
	if err != nil {
		http.Error(w, `{"error": "Unauthorized"}`, http.StatusUnauthorized)
		return
	}

	// Update online status (matching Django's behavior)
	if !IsDeviceOnline(pad.SN) {
		UpdateOnlineStatus(pad.SN)
	}

	// Get Beat object with sync calendar check
	beat := GetBeat(user.ID, user.RelUserID, true)

	// Prepare response data
	data := HeartbeatData{
		EventCate:   beat.EventCate,
		Event:       beat.Event,
		RemindEvent: beat.RemindEvent,
		// ... other fields ...
	}

	// Check if token needs refresh (expires within 3 days)
	if ShouldRefreshToken(user.Exp) {
		if newToken, err := refreshTokenWithDjango(user.ID, user.RelUserID); err == nil {
			data.AccessToken = &newToken
		}
	}

	// Return response
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(HeartbeatResponse{Data: data})
}
```

**职责**：

- 处理心跳请求
- 更新设备在线状态
- 返回同步标志位
- 需要时刷新 JWT token

## 🔄 完整工作流程

下图展示了从接收请求到返回响应的完整处理流程：

```text
┌──────────────────────────────────────────────────────────────┐
│ 1. 程序启动 (main.go)                                         │
│    - init(): 加载环境变量，初始化缓存                          │
│    - main(): 设置路由，启动HTTP服务器                          │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. 接收POST请求: /pad-api/common/heartbeat/                   │
│    Headers:                                                   │
│    - Signature: <加密的设备信息>                               │
│    - Timestamp: <时间戳>                                       │
│    - Authorization: Bearer <JWT token>                        │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. padAuthMiddleware (auth.go) - 第一层认证                    │
│    - 解密Signature header (AES-CBC)                           │
│    - 解析: app_build_num|mac|sn|system_version|timestamp     │
│    - 验证时间戳                                                │
│    - 可选：验证设备序列号                                       │
│    - 将Pad对象存入request context                              │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. heartbeatHandler (handlers.go) - 主处理函数                │
│                                                               │
│    4.1 从context获取Pad设备信息                                │
│    4.2 提取并验证JWT token (jwt.go)                           │
│        - ValidateJWTToken(): 验证签名和有效期                 │
│        - 提取user_id, rel_user_id, expiration                │
│                                                               │
│    4.3 更新设备在线状态 (beat.go)                              │
│        - UpdateOnlineStatus(): 写入Redis SET                 │
│          * device:online:status:{sn} = timestamp (1小时TTL)  │
│          * device:online_devices = SET{sn1, sn2...}          │
│                                                               │
│    4.4 获取Beat同步标志位 (beat.go)                            │
│        - GetBeat(): 从缓存读取                                │
│        - 返回需要同步的数据类型（event, chore, photo...）      │
│        - 读取后清空标志位                                      │
│                                                               │
│    4.5 检查token是否需要刷新 (jwt.go)                          │
│        - ShouldRefreshToken(): 3天内过期？                    │
│        - 如需要，调用Django API获取新token                     │
│                                                               │
│    4.6 构建并返回JSON响应                                      │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     ▼
┌──────────────────────────────────────────────────────────────┐
│ 5. 返回响应                                                    │
│    {                                                          │
│      "data": {                                                │
│        "event": true,        // 需要同步事件                   │
│        "settings": false,    // 设置无需同步                   │
│        "access_token": "..." // 新token (可选)                │
│      }                                                        │
│    }                                                          │
└──────────────────────────────────────────────────────────────┘
```

## 💡 关键设计亮点

### 中间件模式 (Middleware Pattern)

```go
r.HandleFunc("/pad-api/common/heartbeat/",
    padAuthMiddleware(heartbeatHandler)).Methods("POST")
```

先验证签名，再处理业务逻辑，职责分离清晰。

### 接口抽象 (Interface Abstraction)

```go
type CacheBackend interface {
    Get(key string) (interface{}, bool)
    Set(key string, value interface{}, expiration time.Duration) error
    Delete(key string) error
}
```

使用接口抽象，当前仅实现 Redis 后端，确保与 Django 共享缓存数据。

### Context 传递 (Context Propagation)

```go
ctx := context.WithValue(r.Context(), padContextKey, pad)
next.ServeHTTP(w, r.WithContext(ctx))
```

在请求处理链中传递认证信息，避免全局变量。

### 配置管理

使用环境变量+默认值，支持开发和生产环境的灵活切换。

### 与 Django 兼容

- 使用相同的 Redis 键格式
- 兼容 Django 的 JWT 签名算法
- 保持相同的 API 响应结构

---

## 🎯 功能实现对照表

| 功能需求       | 实现位置      | 说明                    |
| -------------- | ------------- | ----------------------- |
| Pad 签名认证   | `auth.go`     | AES-CBC 解密+验证       |
| JWT 直接验证   | `jwt.go`      | 不调用 Django，独立验证 |
| Redis 共享缓存 | `cache.go`    | 与 Django 兼容的键格式  |
| 设备在线状态   | `beat.go`     | 1 小时 TTL              |
| Beat 同步标志  | `beat.go`     | 15 秒 TTL，读后清空     |
| Token 刷新     | `handlers.go` | 3 天内过期自动刷新      |
| 健康检查       | `main.go`     | `/health`端点           |
| Redis 连接检查 | `cache.go`    | 启动时验证 Redis 连接   |

**总结**：这是一个精简但功能完整的 Go 微服务实现，展示了认证、缓存、HTTP 处理等 Go 后端开发的核心技能，同时保持了与 Django 系统的完全兼容性。**注意：Redis 是必需的，服务无法在没有 Redis 的情况下运行。**

---

## Changes Made

### New Go Service (go-heartbeat/)`)

Created a standalone Go service that handles:

- Device heartbeat requests
- Beat synchronization flags
- Device online status tracking
- JWT token refresh
- Internal APIs for Django integration

### Updated Beat Model (pronext/common/models.py)`)

The Beat model now supports dual modes:

- **Local Mode**: Uses Django cache (legacy behavior)
- **Go Service Mode**: Forwards updates to Go service (when `USE_GO_HEARTBEAT_SERVICE=true`)

### Django Integration

Added components for Django to communicate with Go service:

- `pronext/common/heartbeat_client.py`: Client for calling Go service APIs
- `pronext/common/viewset_internal.py`: Internal endpoints for Go service callbacks
- Updated `pronext/common/urls.py`: Registered internal API routes

### Docker Configuration

Updated `docker compose.yml` to include the heartbeat service.

## Deployment Steps

### Step 1: Environment Configuration

The Go heartbeat service is configured via environment variables in `docker compose.yml`. The service requires the following configuration:

```yaml
environment:
  - PORT=8080
  - SIGNING_KEY=FeuaaPVS8uiygdh5Wh9xGUJVxmYKMKD7 # Django's SIGNING_KEY for JWT validation
  - DJANGO_BACKEND_URL=http://api:8888
  - DJANGO_REDIS=redis://:JWvyFWcXRA9fDFY9KmDcWtAxTCyTydAM@redis:6379
  - PAD_API_CHECK_SIGN=false
```

**Configuration Parameters:**

- `PORT`: The port the Go service listens on (default: 8080)
- `SIGNING_KEY`: Must match Django's `SIGNING_KEY` setting for JWT token validation
- `DJANGO_BACKEND_URL`: Django backend URL for token refresh callbacks
- `DJANGO_REDIS`: Redis connection string (must match Django's Redis configuration)
- `PAD_API_CHECK_SIGN`: Enable/disable device signature validation (set to `false` for development)

**Note**: No `.env` file changes are required. All configuration is managed in `docker compose.yml`.

### Step 2: Build and Deploy

```bash
# Build all services
docker compose build

# Start services
docker compose up -d

# Check heartbeat service health
curl http://localhost:8080/health
```

### Step 3: Verify Integration

Test that Django can communicate with the Go service:

```bash
# From Django container, test setting a beat flag
docker compose exec pronext python manage.py shell

>>> from pronext.common.models import Beat
>>> beat = Beat(device_id=1, rel_user_id=1)
>>> beat.should_refresh_settings(True)
# Should succeed without errors
```

### Step 4: Update Client Applications (Optional)

For best performance, update device clients to call the Go service directly:

**Current Django endpoint**:

```http
POST /pad-api/common/heartbeat/
Headers:
  - Authorization: Bearer <jwt-token>
  - Signature: <device-signature>
  - Timestamp: <timestamp>
```

**New Go endpoint**:

```http
POST http://<heartbeat-service-url>:8080/api/heartbeat
Headers:
  - Authorization: Bearer <jwt-token>
  - X-Device-SN: <device-serial>  (or in request body)

Body (optional):
{
  "device_sn": "DEVICE_SERIAL_NUMBER"
}
```

**Note**: The Django endpoint can remain as a proxy during migration.

## Rollback Plan

If issues occur, rollback by:

### Option 1: Disable Go Service Mode

Set in `.env`:

```bash
USE_GO_HEARTBEAT_SERVICE=false
```

Restart Django:

```bash
docker compose restart pronext
```

The Beat model will fall back to using Django cache.

### Option 2: Full Rollback

```bash
# Stop heartbeat service
docker compose stop heartbeat

# Disable in Django
export USE_GO_HEARTBEAT_SERVICE=false
docker compose restart pronext
```

## Monitoring

### Health Checks

**Go Service**:

```bash
curl http://localhost:8080/health
```

**Django Integration**:

```bash
docker compose exec pronext python -c "
from pronext.common.heartbeat_client import heartbeat_client
print('Health:', heartbeat_client.health_check())
"
```

### Online Device Count

**Via Go Service**:

```bash
curl -H "X-Internal-Secret: $JWT_SECRET" \
  http://localhost:8080/internal/online/count
```

**Via Django** (old method still works):

```python
from pronext.common.viewset_pad import get_device_online_count
count = get_device_online_count()
```

## Performance Comparison

### Before (Django + Redis)

- Average heartbeat latency: ~50-100ms
- CPU usage: ~15% per 1000 devices
- Memory: Shared with Django process

### After (Go Service + Memory Cache)

- Average heartbeat latency: ~5-15ms (estimated)
- CPU usage: ~2-5% per 1000 devices (estimated)
- Memory: Dedicated, ~50MB + (50KB per 1000 devices)

## Redis Cache Management

### Understanding Redis Cache Impact

The Go heartbeat service uses Redis to store critical operational data. Understanding what data is stored and the impact of clearing it is essential for safe operations.

### Data Stored in Redis

| Data Type                | Redis Key Pattern                                    | TTL      | Critical? | Impact if Cleared                     |
| ------------------------ | ---------------------------------------------------- | -------- | --------- | ------------------------------------- |
| **Beat Sync Flags**      | `:1:beat1:{device_id}`                               | 15s      | ⚠️ HIGH   | Devices won't know to sync changes    |
| **User Sessions**        | `sessions:{session_id}`                              | 1h       | ⚠️ HIGH   | All users logged out                  |
| **Device Online Status** | `device:online:{sn}`                                 | 1h       | MEDIUM    | Shows 0 devices online temporarily    |
| **Online Devices SET**   | `device:online_devices`                              | 1h       | MEDIUM    | Online count resets, recovers in ~30s |
| **Activation Codes**     | `code:{code}:device:*:user:*`                        | Variable | LOW       | Only affects new device activations   |
| **Sync Calendar Flags**  | `:1:beat:synced_calendar:{device_id}__{rel_user_id}` | 15s      | MEDIUM    | Calendar sync notifications lost      |

### ⚠️ Critical Warning: Impact of Clearing Redis Cache

**DO NOT clear Redis cache in production without understanding the consequences:**

#### Immediate Impact (0-5 seconds)

- ✅ **Existing devices remain authenticated** - JWT tokens are stored on devices, not in Redis
- ❌ **All web users logged out** - Session data is lost
- ❌ **Beat sync flags lost permanently** - No database backup exists
- ❌ **All devices appear offline** - Dashboard shows 0 online devices
- ❌ **Activation codes invalidated** - New device setups will fail

#### Short-term Impact (5-60 seconds)

- ⚠️ **Devices recover automatically** - Next heartbeat (30s interval) restores online status
- ⚠️ **Database query surge** - Cache misses cause DB load spike
- ⚠️ **Sync notifications lost** - Devices won't fetch updates until next change

#### Permanent Data Loss

- **Beat sync flags**: These are transient notifications with NO database backup. Example:

  ```text
  16:00:00 - User creates event
  16:00:01 - Beat flag set: beat1:123 = {event: true}
  16:00:30 - CACHE CLEARED
  16:01:00 - Device heartbeat → empty beat
  Result: Device never learns about the event until next change occurs
  ```

### Safe Cache Clearing Procedures

#### Option 1: Selective Clearing (Recommended)

Clear only non-critical cache keys:

```bash
# Safe to clear - these regenerate from database
redis-cli DEL "pending_update:*"
redis-cli DEL "apk_*"

# Clear old activation codes (if needed)
redis-cli --scan --pattern "code:*" | xargs redis-cli DEL

# DO NOT CLEAR:
# - beat1:*                    (sync flags - no backup!)
# - sessions:*                 (user sessions)
# - device:online:*            (online status)
# - beat:synced_calendar:*     (calendar sync flags)
```

#### Option 2: Full Cache Clear (Emergency Only)

**Only in emergencies** (corruption, critical bug, OOM):

```bash
# 1. Notify all users (they will be logged out)
# 2. Schedule maintenance window
# 3. Clear cache
docker compose exec redis redis-cli FLUSHDB

# 4. Verify services recover
docker compose logs -f heartbeat
docker compose logs -f api
```

**Expected aftermath:**

- All web users must re-login
- Devices miss 1-2 sync notifications (15-30 second window)
- Online device count recovers within 60 seconds
- Activation codes need regeneration

#### Option 3: Memory Optimization (No Data Loss)

Instead of clearing, optimize memory usage:

```bash
# Purge expired keys and free memory
docker compose exec redis redis-cli MEMORY PURGE

# Check memory stats
docker compose exec redis redis-cli INFO memory

# Configure eviction policy (if needed)
docker compose exec redis redis-cli CONFIG SET maxmemory-policy allkeys-lru
```

### Pre-Deployment Cache Clearing

**Safe scenario**: Before deploying Go heartbeat service for the first time:

```bash
# Clear only heartbeat-related keys (safe - service not in use yet)
redis-cli --scan --pattern "beat1:*" | xargs redis-cli DEL
redis-cli --scan --pattern "device:online:*" | xargs redis-cli DEL
redis-cli DEL "device:online_devices"
redis-cli DEL "device:online_count"

# Sessions and activation codes remain intact
# Users stay logged in, devices continue working
```

### Monitoring After Cache Clear

If you must clear cache, monitor these metrics:

```bash
# Check heartbeat service health
curl http://localhost:8080/health

# Monitor Redis keys recovering
watch -n 1 'docker compose exec redis redis-cli DBSIZE'

# Watch online devices recovering
watch -n 5 'docker compose exec redis redis-cli SCARD device:online_devices'

# Check for errors in logs
docker compose logs -f heartbeat | grep -i error
docker compose logs -f api | grep -i error
```

### Decision Matrix: Should I Clear Redis Cache?

| Scenario           | Clear Cache? | Alternative                                |
| ------------------ | ------------ | ------------------------------------------ |
| High memory usage  | ❌ NO        | Use `MEMORY PURGE`                         |
| Testing deployment | ✅ YES       | Clear only `beat1:*` and `device:online:*` |
| Data corruption    | ⚠️ MAYBE     | Try restarting services first              |
| Service migration  | ✅ YES       | Schedule maintenance window                |
| Performance issues | ❌ NO        | Investigate root cause                     |
| OOM errors         | ⚠️ MAYBE     | Check `maxmemory-policy` first             |

### Recovery Checklist

If cache was cleared unexpectedly:

- [ ] Verify heartbeat service is running: `docker compose ps heartbeat`
- [ ] Check Redis connection: `docker compose logs heartbeat | grep -i redis`
- [ ] Monitor online devices recovering: `redis-cli SCARD device:online_devices`
- [ ] Notify users of temporary logout
- [ ] Watch for DB load spike
- [ ] Generate new activation codes if needed
- [ ] Document incident and review cause

## Known Limitations

1. **Redis Dependency**: Service requires Redis connection at startup and runtime
2. **Beat State Transient**: Beat sync flags are not persisted; have 15-second TTL only
3. **No Offline Mode**: Service cannot operate without Redis (by design, to ensure cache consistency with Django)
4. **Token Refresh**: Requires network call to Django backend

## Troubleshooting

### Issue: "Failed to update Go heartbeat service"

**Cause**: Go service is unreachable from Django

**Solution**:

```bash
# Check if heartbeat service is running
docker compose ps heartbeat

# Check logs
docker compose logs heartbeat

# Verify network connectivity
docker compose exec pronext ping heartbeat
```

### Issue: "Invalid token" errors

**Cause**: JWT_SECRET mismatch between Django and Go service

**Solution**:

```bash
# Verify secrets match
docker compose exec pronext python -c "from django.conf import settings; print(settings.SECRET_KEY)"
docker compose exec heartbeat env | grep JWT_SECRET

# Update if needed
docker compose down
# Update .env file
docker compose up -d
```

### Issue: Devices not appearing online

**Cause**: Devices not sending device_sn in requests

**Solution**: Update client to include device SN:

```json
{
  "device_sn": "DEVICE_SERIAL"
}
```

Or via header:

```http
X-Device-SN: DEVICE_SERIAL
```

## Support

For issues or questions:

1. Check service logs: `docker compose logs heartbeat`
2. Verify configuration: Check `.env` and `docker compose.yml`
3. Review service health: `curl http://localhost:8080/health`

## Future Enhancements

Potential improvements:

- [ ] Add metrics/monitoring (Prometheus)
- [ ] Implement rate limiting
- [ ] Add Redis backup option for persistence
- [ ] gRPC support for lower latency
- [ ] Horizontal scaling with shared state
