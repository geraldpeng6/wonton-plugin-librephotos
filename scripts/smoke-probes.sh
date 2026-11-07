# shellcheck shell=bash disable=SC2034

# LibrePhotos：sso=oidc；清单没有 mcp。钩子只用两套 harness 都保证的变量
# （SMOKE_STATE/SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER）和助手（web_get/dweb）。
SSO=oidc
MCP=0

web_assert() { grep -qi '<title>LibrePhotos</title>'; } # stdin：应用真实页面（SPA 首页）

# 应用 API 带着网关登录后 SSO 换来的 JWT；access 只有 5 分钟，过期就用 cookie 里的
# refresh 换新的（未开轮换，refresh 可重复用）。
librephotos_access() {
  local refresh r
  refresh="$(awk '$6=="refresh"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$refresh" ]] || { echo "jar 里没有 refresh cookie"; return 1; }
  r="$(curl -sS --noproxy '*' -H 'Content-Type: application/json' -d "{\"refresh\":\"$refresh\"}" \
    "$SMOKE_WEB_URL/api/auth/token/refresh/")" || { echo "refresh 失败：$r"; return 1; }
  jq -er '.access // empty' <<<"$r"
}

# 走一遍完整 OIDC 链：会话 jar 里的核心会话让 Hydra 自动放行，应用回调把身份换成 JWT
# 落回首页；再用 JWT 调应用的用户接口，确认认出的是用户管理员。
# 失败时打印 SSO 开关状态、链的终点 URL 和页面开头，便于定位断在哪一跳。
identity_check() {
  local access me config final body
  config="$(curl -sS --noproxy '*' --max-time 30 -b "$SMOKE_JAR" "$SMOKE_WEB_URL/api/auth/sso/config")" ||
    { echo "sso/config 请求失败：$config"; return 1; }
  echo "sso/config：$config"
  final="$(curl -sS --noproxy '*' -o /tmp/lp-chain.html -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' -w '%{url_effective}' --max-time 60 \
    "$SMOKE_WEB_URL/api/accounts/oidc/wonton/login/")" ||
    { echo "OIDC 登录链走不通：终点 $final"; return 1; }
  echo "SSO 链终点：$final；jar cookie：$(awk 'NF>=7{printf "%s ", $6}' "$SMOKE_JAR")"
  body="$(head -c 300 /tmp/lp-chain.html 2>/dev/null | tr '\n' ' ')"
  echo "终点页面开头：${body:-（空）}"
  access="$(awk '$6=="access"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$access" ]] || { echo "SSO 后没有 access cookie"; return 1; }
  me="$(curl -sS --noproxy '*' -H "Authorization: Bearer $access" "$SMOKE_WEB_URL/api/user/")" ||
    { echo "/api/user/ 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.results[] | select(.username == $u) | .is_superuser == true' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$(head -c 200 <<<"$me")"; return 1; }
}

# 数据：建一个名字带随机标记的相册（应用的“新建相册”），data_check 按标记找回。
data_write() {
  local access marker r
  marker="wonton-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' -X POST -H "Authorization: Bearer $access" -H 'Content-Type: application/json' \
    -d "{\"title\":\"$marker\",\"photos\":[]}" "$SMOKE_WEB_URL/api/albums/user/edit/")" ||
    { echo "建相册失败：$r"; return 1; }
  jq -e --arg m "$marker" '.title == $m' <<<"$r" >/dev/null ||
    { echo "相册没建成：$(head -c 150 <<<"$r")"; return 1; }
  printf '%s' "$marker" > "$SMOKE_STATE/album-marker"
}

data_check() {
  local access marker r
  marker="$(cat "$SMOKE_STATE/album-marker" 2>/dev/null)" || { echo "没有标记可查"; return 1; }
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' -H "Authorization: Bearer $access" \
    "$SMOKE_WEB_URL/api/albums/user/list/?search=$marker")" || { echo "列相册失败：$r"; return 1; }
  jq -e --arg m "$marker" 'any(.results[]; .title == $m)' <<<"$r" >/dev/null ||
    { echo "标记相册丢了：$(head -c 200 <<<"$r")"; return 1; }
}
