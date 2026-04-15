#!/bin/bash
# =============================================
# 升级API 启动/停止 控制脚本（容器外运行版 + 确认机制）
# 文件名: upgrade_api.sh
# 用法: ./upgrade_api.sh 1   （停止）
#      ./upgrade_api.sh 2   （启动）
# 特点：
#   • 自动取最新 PadApk（.last()，不再写死 id=170）
#   • 显示 v.version + v.build_num + 当前 status
#   • 必须输入 yes 确认后才执行修改
# =============================================

CONTAINER_NAME="pronext"   # ← 如果容器名不是 pronext，请在这里修改

if [ $# -ne 1 ]; then
    echo "❌ 用法错误"
    echo "   ./upgrade_api.sh 1   # 停止升级API"
    echo "   ./upgrade_api.sh 2   # 启动升级API"
    exit 1
fi

STATUS=$1
if [ "$STATUS" != "1" ] && [ "$STATUS" != "2" ]; then
    echo "❌ 参数错误！只能输入 1（停止）或 2（启动）"
    exit 1
fi

ACTION=$( [ "$STATUS" = "1" ] && echo "🛑 停止" || echo "✅ 启动" )

echo "🚀 正在通过 docker 执行：升级API $ACTION（status = $STATUS）..."

# 第一步：获取最新对象信息并显示
echo "📋 正在获取当前最新 PadApk 对象信息..."
INFO=$(docker exec -i "$CONTAINER_NAME" python manage.py shell << 'PYEOF'
v = PadApk.objects.last()
if v is None:
    print("❌ 未找到任何 PadApk 对象！")
else:
    print("=== 当前最新版本信息 ===")
    print(f"id:          {v.id}")
    print(f"version:     {v.version}")
    print(f"build_num:   {v.build_num}")
    print(f"当前 status: {v.status} （1=停止，2=启动）")
    print("=========================")
PYEOF
)

echo "$INFO"

# 如果没找到对象就直接退出
if echo "$INFO" | grep -q "未找到任何 PadApk 对象"; then
    exit 1
fi

# 第二步：让用户确认
read -p "✅ 确认要修改这个版本的状态吗？(输入 yes 继续，否则取消): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "❌ 操作已取消（用户未确认）"
    exit 1
fi

echo "🔄 用户已确认，正在执行状态修改..."

# 第三步：真正执行修改
docker exec -i "$CONTAINER_NAME" python manage.py shell << EOF
v = PadApk.objects.last()
old_status = v.status
v.status = $STATUS
v.save()
print(f"✅ 操作完成！")
print(f"   原状态: {old_status} → 新状态: {v.status}")
print(f"   （1=停止，2=启动）")
print(f"   version: {v.version}   build_num: {v.build_num}")
EOF

# 检查结果
if [ $? -eq 0 ]; then
    echo "🎉 升级API状态已更新为 $STATUS（$ACTION）"
    echo "   [INFO] APK cache 已自动失效"
    echo "   容器: $CONTAINER_NAME"
else
    echo "❌ 执行失败！请检查容器是否正在运行（docker ps）"
fi
