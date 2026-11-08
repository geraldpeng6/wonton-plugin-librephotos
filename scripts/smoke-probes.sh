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
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"refresh\":\"$refresh\"}" "${SMOKE_WEB_URL%/}/api/auth/token/refresh/")" ||
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
  local base access uid code list
  base="${SMOKE_WEB_URL%/}"
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
# 1.5.1 起 GET /api/user/（列用户）在镜像里对这种调法回 404，不再用它。
identity_check() {
  local access uid me
  dweb / >/dev/null 2>&1 || { echo "核心会话没建立"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html' "${SMOKE_WEB_URL%/}/api/accounts/oidc/wonton/login/" ||
    { echo "OIDC 登录链走不通"; return 1; }
  access="$(awk '$6=="access"{print $7}' "$SMOKE_JAR" | tail -1)"
  [[ -n "$access" ]] || { echo "SSO 后没有 access cookie"; return 1; }
  uid="$(jwt_claim "$access" user_id)"
  [[ -n "$uid" ]] || { echo "access JWT 没有 user_id 声明"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "${SMOKE_WEB_URL%/}/api/user/$uid/")" ||
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
  local access marker r
  marker="wonton-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X POST -H "Authorization: Bearer $access" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$marker\",\"photos\":[]}" \
    "${SMOKE_WEB_URL%/}/api/albums/user/edit/")" ||
    { echo "建相册失败：$r"; return 1; }
  jq -e --arg m "$marker" '.title == $m' <<<"$r" >/dev/null ||
    { echo "相册没建成：$(head -c 150 <<<"$r")"; return 1; }
  printf '%s' "$marker" > "$(marker_file)"
}

data_check() {
  local access marker r
  marker="$(cat "$(marker_file)" 2>/dev/null)" || { echo "没有标记可查"; return 1; }
  [[ -n "$marker" ]] || { echo "没有标记可查"; return 1; }
  access="$(librephotos_access)" || return 1
  r="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -H "Authorization: Bearer $access" "${SMOKE_WEB_URL%/}/api/albums/user/list/?search=$marker")" ||
    { echo "列相册失败：$r"; return 1; }
  jq -e --arg m "$marker" 'any(.results[]; .title == $m)' <<<"$r" >/dev/null ||
    { echo "标记相册丢了：$(head -c 200 <<<"$r")"; return 1; }
}
