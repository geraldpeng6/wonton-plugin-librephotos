# shellcheck shell=bash disable=SC2034

# LibrePhotos：sso=oidc；清单没有 mcp。钩子只用两套 harness 都保证的变量
# （SMOKE_STATE/SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER）和助手（web_get/dweb）。
# 应用 API 经核心网关进来：网关认会话 cookie（web_get 自带），JWT 是应用自己的认证，
# 两者都要带。
# SMOKE_WEB_URL 是核心给的“网页地址”，对 sso=oidc 的应用它带着自动登录入口路径
# （…/api/accounts/oidc/wonton/login/）。应用 API 必须接在纯 origin 上：接在它后面
# 会变成 …/login/api/…，应用按 404 回（三轮 CI 实测的“API 全 404”假象就是它）。
# API 调用一律用 app_origin 拼出的 scheme://host:port。
# 下面两行仅给读者速览（sso=oidc、无 mcp），套件并不读取它们：探针套件自己从清单
# 解析（SMOKE_SSO/SMOKE_MCP），e2e 侧在 e2e/plugins/librephotos.sh 里另有同名变量。
SSO=oidc
MCP=0

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

# 数据：建一个名字带随机标记的相册（应用的“新建相册”），标记写进 SMOKE_STATE 文件，
# data_check 读回按标记找回。
marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/librephotos-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

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
  printf '%s' "$marker" > "$(marker_file)"
}

data_check() {
  local access marker r origin
  origin="$(app_origin)" || return 1
  marker="$(cat "$(marker_file)" 2>/dev/null)" || { echo "没有标记可查"; return 1; }
  [[ -n "$marker" ]] || { echo "没有标记可查"; return 1; }
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "$origin/api/albums/user/list/?search=$marker")" ||
    { echo "列相册失败：$r"; return 1; }
  jq -e --arg m "$marker" 'any(.results[]; .title == $m)' <<<"$r" >/dev/null ||
    { echo "标记相册丢了：$(head -c 200 <<<"$r")"; return 1; }
}

# ---------- 邮件（notify）：找回密码的信经核心内部邮箱投进主人私聊 ----------
# LibrePhotos 的重置接口永远回 200（防枚举），发信失败只记日志不外显，所以「接口 200」不说明信发出了；
# 触发后以主人身份读 Matrix 私聊里的 app.wonton.plugin_mail 消息为投递证据（ EmailConfig 由 bootstrap
# 写库，发信走的就是核心注入的 SMTP——配置不对的话 send_mail 连不上，私聊里就不会有信）。
# 发往不存在的邮箱时上游根本不发（防枚举），外部 550 拒收在这条触发路径上不可观测，不写假断言。
extra_check() {
  local origin bootstrap mail_host mail_port mail_from access out
  origin="$(app_origin)"
  declare -F owner_access_token >/dev/null ||
    { echo "需要 e2e 套件的 owner_access_token（读主人私聊拿投递证据用）"; return 1; }

  # 0) 三个 SMTP 变量进了 bootstrap 容器（core 在安装时注入；EmailConfig 由它写库）
  bootstrap="$(docker ps -a --format '{{.Names}}' | grep -E "wonton-${SMOKE_INSTANCE}--app-librephotos-librephotos--bootstrap$" | head -1)"
  [[ -n "$bootstrap" ]] || { echo "找不到 bootstrap 容器"; return 1; }
  mail_host="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_SMTP_HOST=//p' | tail -1)"
  mail_port="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_SMTP_PORT=//p' | tail -1)"
  mail_from="$(docker inspect "$bootstrap" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^WONTON_MAIL_FROM=//p' | tail -1)"
  [[ "$mail_host" == "smtp.wonton.internal" && "$mail_port" == "25" &&
    "$mail_from" == "app.librephotos.librephotos@plugins.wonton.internal" ]] ||
    { echo "SMTP 变量不对：host=$mail_host port=$mail_port from=$mail_from"; return 1; }
  echo "SMTP 变量已注入 bootstrap：$mail_host:$mail_port from=$mail_from"

  # 1) 触发找回密码（发给主人账号的邮箱；上游同步 send_mail，接口永远 200）
  local owner_email mtok before_ts found json seen_room
  owner_email="${SMOKE_OWNER_EMAIL:-${SMOKE_OWNER:+"${SMOKE_OWNER}@wonton.internal"}}"
  owner_email="${owner_email:-$(probes_setting WONTON_OWNER_EMAIL 2>/dev/null)}"
  [[ -n "$owner_email" ]] || { echo "拿不到 WONTON_OWNER_EMAIL（SMOKE_OWNER_EMAIL/read_env 都为空）"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -H 'Content-Type: application/json' \
    -d "{\"email\":\"$owner_email\"}" "$origin/api/auth/password/reset/")" ||
    { echo "找回密码请求失败：$out"; return 1; }
  jq -e '.status == true' <<<"$out" >/dev/null || { echo "重置接口回执异常：$out"; return 1; }
  echo "找回密码已请求（接口 200；是否发出以私聊为准）"

  # 2) 以主人身份读私聊，等 app.wonton.plugin_mail 消息（成功投递在核心日志里静默）
  mtok="$(owner_access_token)" || { echo "主人 Matrix 登录失败（读私聊拿投递证据用）"; return 1; }
  before_ts="$(date +%s000)"
  found=""
  for _ in $(seq 1 50); do
    seen_room="$(matrix_curl -H "Authorization: Bearer $mtok" \
      "http://tuwunel.wonton.internal:8008/_matrix/client/v3/joined_rooms" 2>/dev/null | jq -r '.joined_rooms[]' 2>/dev/null)" || { sleep 3; continue; }
    while IFS= read -r room; do
      [[ -n "$room" ]] || continue
      json="$(matrix_curl -H "Authorization: Bearer $mtok" \
        "http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$(printf '%s' "$room" | sed 's/!/%21/g;s/:/%3A/g')/messages?dir=b&limit=30" 2>/dev/null)" || continue
      if jq -e --arg p "app.librephotos.librephotos" --argjson t "$before_ts" '.chunk[] |
          select(.type == "m.room.message" and .origin_server_ts >= $t and
          .content["app.wonton.plugin_mail"].plugin_id == $p)' <<<"$json" >/dev/null 2>&1; then
        found="$room"
        break
      fi
    done <<<"$seen_room"
    [[ -n "$found" ]] && break
    sleep 3
  done
  [[ -n "$found" ]] || { echo "主人的 Wonton 私聊里没有 LibrePhotos 的重置信（150 秒）"; return 1; }
  echo "核心已把 LibrePhotos 的重置信投进主人的 Wonton 私聊（房间 $found）"
}
