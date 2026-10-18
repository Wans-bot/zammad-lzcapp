#!/bin/sh
# Zammad 单容器启动脚本：先跑 init（数据库迁移 + seeds + ES 索引），
# 再后台拉起 scheduler 与 websocket，最后前台跑 railsserver。
# 之所以放在一个容器里：这几个进程共用镜像与环境变量，拆开会让平台就绪门
# 多出三个没有 HTTP 探针的服务（scheduler 无法用 HTTP 探活）。
set -e
ENTRY=/opt/zammad/bin/docker-entrypoint
WIZARD=/opt/zammad/tmp/auto_wizard.json
WIZARD_ALT=/opt/zammad/auto_wizard.json

# ── 权限自愈（2026-10-13 返工 #20237）───────────────────────────────────────
# 容器以 root 启动（manifest 的 user: "0"）：先把持久目录修到 zammad(1000) 名下，
# 再以 zammad 用户重入本脚本。替代原先的 run_as: 1000 —— 平台的 run_as 走
# idmapped 挂载，在「重装」场景会让容器创建失败：
#   mkdir .../idmapped/.../zammad-var-1000-1000/storage: value too large for
#   defined data type   （compose exit status 1，应用起不来）
if [ "$(id -u)" = "0" ]; then
  chown -R 1000:1000 /lzcapp/var/storage 2>/dev/null || true
  exec su -s /bin/sh zammad -c "exec /bin/sh /lzcapp/pkg/content/zammad/start-app.sh"
fi

# 平台每次升级/重装都是新容器，/opt/zammad/tmp 不持久；镜像自带的 zammad-init
# 只在「数据库还没有用户」那次写入 auto_wizard.json，升级后就再也不会写。
# 这里每次启动都按环境变量重放一份，保证 auto wizard 一定能拿到配置。
# JSON 在本脚本里用 heredoc 拼，避免把长 base64 塞进 manifest（实测会被改坏一个字节）。
if [ -n "${LZC_ADMIN_LOGIN:-}" ] && [ -n "${LZC_ADMIN_PASSWORD:-}" ]; then
  ORG="${LZC_ORG_NAME:-我的团队}"
  cat > "$WIZARD" <<JSONEOF
{
  "Organizations": [{"name": "${ORG}"}],
  "Users": [
    {
      "login": "${LZC_ADMIN_LOGIN}",
      "firstname": "${LZC_ADMIN_FIRSTNAME:-管理员}",
      "lastname": "${LZC_ADMIN_LASTNAME:-账号}",
      "email": "${LZC_ADMIN_LOGIN}",
      "organization": "${ORG}",
      "password": "${LZC_ADMIN_PASSWORD}"
    }
  ],
  "Settings": [
    {"name": "product_name", "value": "${LZC_PRODUCT_NAME:-Zammad 工单系统}"},
    {"name": "locale_default", "value": "${LZC_LOCALE:-zh-cn}"}
  ]
}
JSONEOF
  cp "$WIZARD" "$WIZARD_ALT" 2>/dev/null || true
fi

echo "[lzc-zammad] zammad-init: 迁移数据库 / seeds / 索引..."
"$ENTRY" zammad-init

echo "[lzc-zammad] 启动 scheduler 与 websocket（后台）..."
"$ENTRY" zammad-scheduler >/tmp/lzc-scheduler.log 2>&1 &
"$ENTRY" zammad-websocket >/tmp/lzc-websocket.log 2>&1 &

# 免密首启：等 rails 起来后调用官方 auto wizard 接口完成「建组织 + 建管理员 +
# 设置默认语言」，并把 system_init_done 置真。这样用户打开页面只会看到普通登录页，
# 由 simple-inject-password 注入自动填充登录，全程不需要手打账号密码。
echo "[lzc-zammad] 后台等待 rails 就绪并执行 auto wizard ..."
(
  i=0
  while [ "$i" -lt 120 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${ZAMMAD_RAILSSERVER_PORT:-3000}/"; then
      break
    fi
    i=$((i + 1))
    sleep 3
  done
  curl -sS "http://127.0.0.1:${ZAMMAD_RAILSSERVER_PORT:-3000}/api/v1/getting_started/auto_wizard" \
    >/tmp/lzc-autowizard.json 2>/tmp/lzc-autowizard.err || true
  # 成功（或系统已配置）后清掉备用文件，避免 guided setup 页再被触发
  if grep -q 'auto_wizard_success":true\|already been configured' /tmp/lzc-autowizard.json 2>/dev/null; then
    rm -f "$WIZARD_ALT" 2>/dev/null || true
  fi
) &

echo "[lzc-zammad] 启动 railsserver（前台）..."
exec "$ENTRY" zammad-railsserver
