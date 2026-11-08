# shellcheck shell=bash disable=SC2034

# LibrePhotos：sso=oidc；清单没有 mcp。钩子只用两套 harness 都保证的变量
# （SMOKE_STATE/SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER）和助手（web_get/dweb）。
# 应用 API 经核心网关进来：网关认会话 cookie（web_get 自带），JWT 是应用自己的认证，
# 两者都要带。
# 下面两行仅给读者速览（sso=oidc、无 mcp），套件并不读取它们：探针套件自己从清单
# 解析（SMOKE_SSO/SMOKE_MCP），e2e 侧在 e2e/plugins/librephotos.sh 里另有同名变量。
SSO=oidc
MCP=0

web_assert() { grep -qi '<title>LibrePhotos</title>'; } # stdin：应用真实页面（SPA 首页）

# 应用 API 带着网关登录后 SSO 换来的 JWT；access 只有 5 分钟，过期就用 cookie 里的
# refresh 换新的（未开轮换，refresh 可重复用）。
librephotos_access() {
  local refresh r
  refresh="$(awk '$6=="refresh"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$refresh" ]] || { echo "jar 里没有 refresh cookie"; return 1; }
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"refresh\":\"$refresh\"}" "$SMOKE_WEB_URL/api/auth/token/refresh/")" ||
    { echo "refresh 失败：$r"; return 1; }
  jq -er '.access // empty' <<<"$r"
}

# 走一遍完整 OIDC 链：会话 jar 里的核心会话让 Hydra 自动放行，应用回调把身份换成 JWT
# 落回首页；再用 JWT + 会话调应用的用户接口，确认认出的是用户管理员。
identity_check() {
  local access me
  dweb / >/dev/null 2>&1 || { echo "核心会话没建立"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "$SMOKE_WEB_URL/api/accounts/oidc/wonton/login/" ||
    { echo "OIDC 登录链走不通"; return 1; }
  access="$(awk '$6=="access"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$access" ]] || { echo "SSO 后没有 access cookie"; return 1; }
  me="$(web_get /api/user/ -H "Authorization: Bearer $access")" ||
    { echo "/api/user/ 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.results[] | select(.username == $u) | .is_superuser == true' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$(head -c 200 <<<"$me")"; return 1; }
}

# 数据：建一个名字带随机标记的相册（应用的“新建相册”），标记写进 SMOKE_STATE 文件，
# data_check 读回按标记找回。
data_write() {
  local access marker r
  marker="wonton-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  access="$(librephotos_access)" || return 1
  r="$(web_get /api/albums/user/edit/ -X POST -H "Authorization: Bearer $access" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$marker\",\"photos\":[]}")" ||
    { echo "建相册失败：$r"; return 1; }
  jq -e --arg m "$marker" '.title == $m' <<<"$r" >/dev/null ||
    { echo "相册没建成：$(head -c 150 <<<"$r")"; return 1; }
  printf '%s' "$marker" > "$SMOKE_STATE"
}

data_check() {
  local access marker r
  marker="$(cat "$SMOKE_STATE" 2>/dev/null)" || { echo "没有标记可查"; return 1; }
  [[ -n "$marker" ]] || { echo "没有标记可查"; return 1; }
  access="$(librephotos_access)" || return 1
  r="$(web_get "/api/albums/user/list/?search=$marker" -H "Authorization: Bearer $access")" ||
    { echo "列相册失败：$r"; return 1; }
  jq -e --arg m "$marker" 'any(.results[]; .title == $m)' <<<"$r" >/dev/null ||
    { echo "标记相册丢了：$(head -c 200 <<<"$r")"; return 1; }
}
