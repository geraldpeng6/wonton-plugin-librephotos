# shellcheck shell=bash disable=SC2034

# LibrePhotos：OIDC（sso=oidc）；清单没有 mcp。
# 应用 API 经核心网关进来：网关认会话 cookie（web_get 自带），JWT 是应用自己的认证，两者都要带。
# SMOKE_WEB_URL 是核心给的“网页地址”，对 sso=oidc 的应用它带着自动登录入口路径
# （…/api/accounts/oidc/wonton/login/）。应用 API 必须接在纯 origin 上：接在它后面
# 会变成 …/login/api/…，应用按 404 回（三轮 CI 实测的“API 全 404”假象就是它）。
# API 调用一律用 app_origin 拼出的 scheme://host:port。

web_assert() { grep -qi '<title>LibrePhotos</title>'; } # stdin：应用真实页面（SPA 首页）

# 应用的纯 origin（scheme+host+port）；SMOKE_WEB_URL 无论带不带登录路径都成立。
app_origin() {
  [[ "$SMOKE_WEB_URL" =~ ^https?://[^/]+ ]] || { echo "SMOKE_WEB_URL 里没有 origin：$SMOKE_WEB_URL"; return 1; }
  printf '%s' "${BASH_REMATCH[0]}"
}

# 应用 API 带着网关登录后 SSO 换来的 JWT；access 只有 5 分钟，过期就用 cookie 里的
# refresh 换新的（未开轮换，refresh 可重复用）。
librephotos_access() {
  local refresh r
  refresh="$(awk '$6=="refresh"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$refresh" ]] || { echo "jar 里没有 refresh cookie"; return 1; }
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"refresh\":\"$refresh\"}" "$(app_origin)/api/auth/token/refresh/")" ||
    { echo "refresh 失败：$r"; return 1; }
  jq -er '.access // empty' <<<"$r"
}

# 解 JWT payload 里的一个声明（base64url，无填充）。
jwt_claim() { # <token> <claim>
  python3 - "$1" "$2" <<'PY'
import base64, json, sys
payload = sys.argv[1].split(".")[1]
payload += "=" * (-len(payload) % 4)
value = json.loads(base64.urlsafe_b64decode(payload)).get(sys.argv[2], "")
print(value if value is not None else "")
PY
}

# 身份失败时的诊断：一行打全各路由的状态码（网关外侧实测），再看 404 是谁答的。
probe_diag() { # <access> <uid>
  local base access uid code p list
  base="$(app_origin)" || return 0
  access="$1"
  uid="$2"
  list="api/healthz/ready/ api/auth/sso/config/ api/firsttimesetup/ api/sitesettings/ api/imagetag/ api/user/ api/user/$uid/ api/auth/token/refresh/ api/albums/user/list/ api/no-such-route-diag/"
  for p in $list; do
    code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 -b "$SMOKE_JAR" \
      -H "Authorization: Bearer $access" "$base/$p")" || code="ERR"
    p="${p%/}"
    printf '%s=%s ' "${p%%/*}/…${p##*/}" "$code"
  done
  echo
  echo "404 响应头：$(curl -sS --noproxy '*' -o /dev/null -D - --max-time 20 -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "$base/api/user/" 2>&1 | grep -aiE '^(server|content-type|x-wonton):' | tr -d '\r' | tr '\n' ' ')"
}

# 走一遍完整 OIDC 链：会话 jar 里的核心会话让 Hydra 自动放行，应用回调把身份换成 JWT
# 落回首页；再按现行前端的取法（useCurrentUserSelfDetailsQuery：access JWT 的 user_id
# 声明 → GET /api/user/<id>/）调应用的用户接口，确认认出的是用户管理员。
identity_check() {
  local access uid me origin
  origin="$(app_origin)" || return 1
  dweb / >/dev/null 2>&1 || { echo "核心会话没建立"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$origin/api/accounts/oidc/wonton/login/" ||
    { echo "OIDC 登录链走不通"; return 1; }
  access="$(awk '$6=="access"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$access" ]] || { echo "SSO 后没有 access cookie"; return 1; }
  uid="$(jwt_claim "$access" user_id)"
  [[ -n "$uid" ]] || { echo "access JWT 没有 user_id 声明"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "$origin/api/user/$uid/")" ||
    { probe_diag "$access" "$uid"; echo "/api/user/$uid/ 失败：$(head -c 160 <<<"$me")"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u and .is_superuser == true' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$(head -c 200 <<<"$me")"; return 1; }
}

# 数据：建一个名字带随机标记的相册（应用的“新建相册”），标记写进 $SMOKE_STATE，
# data_check 读回按标记找回。
data_write() {
  local access marker r origin
  origin="$(app_origin)" || return 1
  marker="wonton-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X POST -H "Authorization: Bearer $access" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$marker\",\"photos\":[]}" \
    "$origin/api/albums/user/edit/")" ||
    { echo "建相册失败：$r"; return 1; }
  jq -e --arg m "$marker" '.title == $m' <<<"$r" >/dev/null ||
    { echo "相册没建成：$(head -c 150 <<<"$r")"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local access marker r origin
  origin="$(app_origin)" || return 1
  marker="$(cat "$SMOKE_STATE" 2>/dev/null)" || marker=""
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "$origin/api/albums/user/list/?search=$marker")" ||
    { echo "列相册失败：$r"; return 1; }
  jq -e --arg m "$marker" 'any(.results[]; .title == $m)' <<<"$r" >/dev/null ||
    { echo "标记相册丢了：$(head -c 200 <<<"$r")"; return 1; }
}

# ---------- 邮件（notify）：找回密码的信经核心内部邮箱投进主人私聊 ----------
# LibrePhotos 的重置接口永远回 200（防枚举），发信失败只记日志不外显，所以「接口 200」不说明信发出了；
# 触发后等套件的通知房间助手看到投递（邮件正文以插件名开头，断言“LibrePhotos”）。
# EmailConfig 由 bootstrap 写库，发信走的就是核心注入的 SMTP——配置不对的话 send_mail 连不上，私聊里就不会有信。
# 发往不存在的邮箱时上游根本不发（防枚举），外部 550 拒收在这条触发路径上不可观测，不写假断言。
extra_check() {
  local origin bootstrap mail_host mail_port mail_from out wp
  origin="$(app_origin)"

  # 0) 三个 SMTP 变量进了 bootstrap 容器（core 在安装时注入；EmailConfig 由它写库）。
  #    bootstrap 是一次性的，跑完就退出，所以要 -a 连退出的容器一起找。
  bootstrap="$(docker ps -a --format '{{.Names}}' \
    --filter "label=wonton.plugin=$SMOKE_PLUGIN_ID" --filter "label=wonton.service=bootstrap" \
    --filter "label=wonton.instance=${SMOKE_INSTANCE//-/}" | head -1)"
  [[ -n "$bootstrap" ]] || { echo "找不到 bootstrap 容器"; return 1; }
  mail_host="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_SMTP_HOST=//p' | tail -1)"
  mail_port="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_SMTP_PORT=//p' | tail -1)"
  mail_from="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_MAIL_FROM=//p' | tail -1)"
  [[ "$mail_host" == "smtp.wonton.internal" && "$mail_port" == "25" &&
    "$mail_from" == "${SMOKE_PLUGIN_ID}@plugins.wonton.internal" ]] ||
    { echo "SMTP 变量不对：host=$mail_host port=$mail_port from=$mail_from"; return 1; }
  echo "SMTP 变量已注入 bootstrap：$mail_host:$mail_port from=$mail_from"

  # 1) 触发找回密码（发给主人的内部地址：身份声明和应用账号里的邮箱都是它，核心也只收这个域）。
  # 网关的会话 Cookie 落在插件域名上要先走一遍核心登录+插件首页跳转（jar 里只有核心域的 Cookie 不够）。
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login"
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$SMOKE_WEB_URL/"
  # 等待先挂后台再触发（套件的用法）：信进私聊是秒级投递，先等后发才等得到。
  probes_owner_room_wait 150 "LibrePhotos" & wp=$!
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${SMOKE_OWNER}@wonton.internal\"}" "$origin/api/auth/password/reset/")" ||
    { kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; echo "找回密码请求失败：$out"; return 1; }
  jq -e '.status == true' <<<"$out" >/dev/null || {
    kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
    echo "重置接口回执异常：$out"; return 1
  }
  echo "找回密码已请求（接口 200；是否发出以私聊为准）"

  # 2) 等核心把重置信投进主人的 Wonton 私聊（投递在核心日志里静默）
  wait "$wp" || { echo "150 秒没等到重置信进私聊：上面是通知房间的最新消息"; return 1; }
  echo "核心已把 LibrePhotos 的重置信投进主人的 Wonton 私聊"
}
