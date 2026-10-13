#!/bin/bash
# ================================================================
#  上传到 GitHub（双击运行）
#
#  作用：
#    1. 把这个脚本所在文件夹里的所有文件上传到你的 GitHub 仓库；
#    2. 如果里面有 HTML 文件，给出在线预览地址，并自动用浏览器打开。
#
#  首次运行优先使用 GitHub CLI（gh）的登录状态，无需任何配置；
#  如果电脑上没有 gh，则引导你输入一次 GitHub 用户名和访问令牌，
#  令牌会保存到 macOS 钥匙串，之后双击就自动上传。
# ================================================================

# 双击时如果被 zsh 之类的 shell 打开，先切回 bash
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi

set -uo pipefail

# ---------------- 路径与全局变量 ----------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
cd -- "$SCRIPT_DIR" || exit 1

FOLDER="$SCRIPT_DIR"
FOLDER_NAME="$(basename -- "$FOLDER")"

CONFIG_DIR="$HOME/.config/upload-to-github"
CONFIG_FILE="$CONFIG_DIR/config"
REPOS_FILE="$CONFIG_DIR/repos"
KEYCHAIN_SERVICE="Upload-to-GitHub"

API_BASE="${UPLOAD_GITHUB_API_BASE:-https://api.github.com}"
GITHUB_HOST="${UPLOAD_GITHUB_HOST:-github.com}"
REMOTE_BASE="${UPLOAD_GITHUB_REMOTE_BASE:-https://$GITHUB_HOST}"

TOKEN=""
GITHUB_USER=""
REPO_VISIBILITY="public"
HTTP_CODE=""
HTTP_BODY=""

# ---------------- 输出与交互 ----------------
pause() {
  printf '\n按回车键关闭窗口 ... '
  read -r _ 2>/dev/null || true
  printf '\n'
}

die() {
  printf '\n[错误] %s\n' "$1" >&2
  pause
  exit 1
}

say()  { printf '%s\n' "$1"; }
ok()   { printf '[完成] %s\n' "$1"; }
warn() { printf '[注意] %s\n' "$1"; }

ask_text() { # ask_text "提示" "默认值" 变量名
  local prompt="$1" default_value="$2" __var="$3" answer=""
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$prompt" "$default_value"
  else
    printf '%s: ' "$prompt"
  fi
  if ! read -r answer; then
    printf '\n'
    die "没有读到输入（窗口可能被关闭了），已退出。"
  fi
  [ -z "$answer" ] && answer="$default_value"
  printf -v "$__var" '%s' "$answer"
}

ask_secret() { # ask_secret "提示" 变量名
  local prompt="$1" __var="$2" answer=""
  printf '%s' "$prompt"
  if ! read -r -s answer; then
    printf '\n'
    die "没有读到输入（窗口可能被关闭了），已退出。"
  fi
  printf '\n'
  printf -v "$__var" '%s' "$answer"
}

ask_yes() { # 只在明确输入 y 时返回 0
  local answer=""
  printf '%s [y/N]: ' "$1"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- GitHub API ----------------
api_request() { # api_request METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}" response=""
  if [ -n "$body" ]; then
    response="$(curl -sS -m 30 -X "$method" \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $TOKEN" \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: upload-to-github-command' \
      -d "$body" \
      -w $'\n%{http_code}' \
      "$API_BASE$path" 2>/dev/null)" || response=""
  else
    response="$(curl -sS -m 30 -X "$method" \
      -H 'Accept: application/vnd.github+json' \
      -H "Authorization: Bearer $TOKEN" \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'User-Agent: upload-to-github-command' \
      -w $'\n%{http_code}' \
      "$API_BASE$path" 2>/dev/null)" || response=""
  fi

  if [ -z "$response" ]; then
    HTTP_CODE="000"
    HTTP_BODY=""
  else
    HTTP_CODE="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
    [ "$HTTP_BODY" = "$response" ] && HTTP_BODY=""
  fi
}

api_error_message() { # 把 GitHub 返回的 message 字段抠出来，方便看
  printf '%s' "$HTTP_BODY" \
    | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

api_login_field() { # 从 /user 响应里取 login
  printf '%s' "$HTTP_BODY" \
    | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

api_json_bool() { # 取响应里的 true/false 字段，例如 api_json_bool private
  printf '%s' "$HTTP_BODY" \
    | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' \
    | head -n 1
}

token_works() {
  [ -n "$TOKEN" ] || return 1
  api_request GET /user
  [ "$HTTP_CODE" = "200" ]
}

# ---------------- 小工具 ----------------
slugify() { # 把文件夹名变成合法的仓库名
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9._-]/-/g' -e 's/-\{2,\}/-/g' \
    | LC_ALL=C sed -e 's/^[-.]*//' -e 's/[-.]*$//'
}

url_encode_segment() { # 单个路径片段做 URL 编码（按字节处理，中文名也能用）
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    {
      out = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /^[A-Za-z0-9._~-]$/) out = out c
        else out = out sprintf("%%%02X", ord[c])
      }
      printf "%s", out
    }'
}

has_non_ascii() { # 文件夹名里是否含中文等非 ASCII 字符
  LC_ALL=C grep -q '[^ -~]' <<ASCII_EOF
$1
ASCII_EOF
}

transliterate() { # 中文等非英文名字转拼音（用 macOS 自带的 Foundation 转换）
  osascript -l JavaScript -e '
    ObjC.import("Foundation");
    function run(argv) {
      var ms = $.NSMutableString.stringWithString(argv[0]);
      var out = ms.stringByApplyingTransformReverse("Any-Latin; Latin-ASCII;", false);
      return ObjC.unwrap(out);
    }' "$1" 2>/dev/null
}

auto_repo_name() { # 自动取仓库名：英文直接用，中文转拼音，都不行就用日期
  local raw="$1" slug candidate
  slug="$(slugify "$raw")"
  if [ -n "$slug" ] && ! has_non_ascii "$raw"; then
    printf '%s' "$slug"
    return 0
  fi
  candidate="$(transliterate "$raw")"
  if [ -n "$candidate" ]; then
    slug="$(slugify "$candidate")"
  fi
  if [ -n "$slug" ]; then
    slug="$(slugify "${slug:0:60}")"
    printf '%s' "$slug"
    return 0
  fi
  printf 'web-%s' "$(date '+%Y%m%d-%H%M%S')"
}

url_encode_path() { # 路径按 / 分段编码，保留斜杠
  local path="$1" out="" seg
  local -a parts=()
  local IFS='/'
  # shellcheck disable=SC2206
  parts=($path)
  local first=1
  for seg in "${parts[@]}"; do
    if [ "$first" = "1" ]; then
      first=0
    else
      out="$out/"
    fi
    out="$out$(url_encode_segment "$seg")"
  done
  printf '%s' "$out"
}

keychain_token() {
  security find-generic-password -a "$1" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true
}

keychain_save_token() {
  security add-generic-password -a "$1" -s "$KEYCHAIN_SERVICE" -w "$2" -U >/dev/null 2>&1
}

save_config() {
  mkdir -p "$CONFIG_DIR" || return 1
  umask 077
  printf 'GITHUB_USER=%s\nREPO_VISIBILITY=%s\n' "$GITHUB_USER" "$REPO_VISIBILITY" > "$CONFIG_FILE"
}

load_config() {
  GITHUB_USER=""
  REPO_VISIBILITY="public"
  VISIBILITY_KNOWN=0
  if [ -f "$CONFIG_FILE" ]; then
    if grep -q '^REPO_VISIBILITY=' "$CONFIG_FILE" 2>/dev/null; then
      VISIBILITY_KNOWN=1
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE" >/dev/null 2>&1 || true
    case "$REPO_VISIBILITY" in
      public|private) : ;;
      *) REPO_VISIBILITY="public"; VISIBILITY_KNOWN=0 ;;
    esac
  fi
}

remember_repo() { # remember_repo owner/repo
  mkdir -p "$CONFIG_DIR" || return 0
  local tmp="$REPOS_FILE.tmp"
  : > "$tmp" || return 0
  if [ -f "$REPOS_FILE" ]; then
    awk -F '\t' -v p="$FOLDER" '$1 != p' "$REPOS_FILE" >> "$tmp"
  fi
  printf '%s\t%s\n' "$FOLDER" "$1" >> "$tmp"
  mv "$tmp" "$REPOS_FILE" 2>/dev/null || true
}

recall_repo() { # 从记录里读回这个文件夹对应的仓库
  [ -f "$REPOS_FILE" ] || return 0
  awk -F '\t' -v p="$FOLDER" '$1 == p { print $2; exit }' "$REPOS_FILE"
}

parse_owner_repo() { # 从 git remote 地址里取出 owner/repo
  printf '%s' "$1" | sed -E \
    -e 's#^git@[^:]+:##' \
    -e 's#^ssh://git@[^/]+/##' \
    -e 's#^https?://[^/]+/##' \
    -e 's#\.git$##' \
    -e 's#/+$##'
}

git_askpass_setup() {
  ASKPASS_FILE="$(mktemp -t uploadgithub.XXXXXX)" || return 1
  cat > "$ASKPASS_FILE" <<'ASKPASS_EOF'
#!/bin/bash
case "$1" in
  *sername*) printf '%s\n' "$UG_USERNAME" ;;
  *assword*) printf '%s\n' "$UG_PASSWORD" ;;
  *) printf '\n' ;;
esac
ASKPASS_EOF
  chmod 700 "$ASKPASS_FILE"
  export UG_USERNAME="$GITHUB_USER"
  export UG_PASSWORD="$TOKEN"
  export GIT_ASKPASS="$ASKPASS_FILE"
  export GIT_TERMINAL_PROMPT=0
}

git_askpass_cleanup() {
  unset UG_USERNAME UG_PASSWORD GIT_ASKPASS GIT_TERMINAL_PROMPT 2>/dev/null || true
  [ -n "${ASKPASS_FILE:-}" ] && rm -f "$ASKPASS_FILE"
  ASKPASS_FILE=""
}

is_network_error() { # 判断 git 的报错是不是网络问题（这些情况值得自动重试）
  case "$1" in
    *"HTTP2 framing layer"*|*"RPC failed"*|*"remote end hung up"*|*"Connection reset"*|*"early EOF"*|*"Failed to connect"*|*"Could not resolve host"*|*"Connection timed out"*|*"unable to access"*|*"GnuTLS"*|*"SSL_ERROR"*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

ssh_over_443_works() { # github.com 被墙时，GitHub 的 443 端口 SSH 通道通常还能用
  local out
  command -v ssh >/dev/null 2>&1 || return 1
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
        -T -p 443 git@ssh.github.com 2>&1)"
  case "$out" in
    *"successfully authenticated"*|*"Hi "*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_http_proxy() { # 找一个能连上 GitHub 的本机代理（Clash / Surge / V2Ray 之类）
  local env_proxy port host system_host system_port
  env_proxy="${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}"
  if [ -n "$env_proxy" ]; then
    printf '%s' "$env_proxy"
    return 0
  fi

  # macOS 系统代理设置（开着的话优先用）
  system_host="$(scutil --proxy 2>/dev/null | awk -F': ' '/HTTPSProxy/{gsub(/ /,"",$2); print $2}' | head -n 1)"
  system_port="$(scutil --proxy 2>/dev/null | awk -F': ' '/HTTPSPort/{gsub(/ /,"",$2); print $2}' | head -n 1)"
  if [ -n "$system_host" ] && [ -n "$system_port" ]; then
    if curl -sS -o /dev/null -m 8 -x "http://${system_host}:${system_port}" 'https://github.com/' >/dev/null 2>&1; then
      printf 'http://%s:%s' "$system_host" "$system_port"
      return 0
    fi
  fi

  # 常见本地代理端口
  for port in 7897 7890 7891 7899 1087 1080 8888 6152 8118 10809; do
    nc -z -G 1 127.0.0.1 "$port" >/dev/null 2>&1 || continue
    if curl -sS -o /dev/null -m 8 -x "http://127.0.0.1:$port" 'https://github.com/' >/dev/null 2>&1; then
      printf 'http://127.0.0.1:%s' "$port"
      return 0
    fi
  done
  return 1
}

# ---------------- 开始 ----------------

# 仅用于测试：只加载上面的函数，不执行上传流程
if [ "${UPLOAD_GITHUB_SOURCE_ONLY:-0}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

say "=============================================="
say " 上传文件夹到 GitHub"
say " 文件夹：$FOLDER"
say "=============================================="
say ""

command -v git >/dev/null 2>&1 || die "没有找到 git。请先在终端执行 xcode-select --install 安装命令行工具，再重新双击本脚本。"
command -v curl >/dev/null 2>&1 || die "没有找到 curl（系统自带，正常情况下不会缺），无法连接 GitHub。"

load_config

# ---- 第 1 步：确定用什么身份登录 ----
# 双击打开时 PATH 偶尔不含 Homebrew，先补上，免得找不到 gh
if ! command -v gh >/dev/null 2>&1; then
  for _dir in /opt/homebrew/bin /usr/local/bin; do
    [ -x "$_dir/gh" ] && PATH="$PATH:$_dir"
  done
  export PATH
  unset _dir
fi

GOT_CREDS=0

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh_token="$(gh auth token 2>/dev/null || true)"
  if [ -n "$gh_token" ]; then
    TOKEN="$gh_token"
    if token_works; then
      gh_login="$(api_login_field)"
      [ -n "$gh_login" ] && GITHUB_USER="$gh_login"
      GOT_CREDS=1
      ok "已使用 GitHub CLI 登录的账号：$GITHUB_USER"
    fi
    gh_token=""
  fi
fi

if [ "$GOT_CREDS" = "0" ] && [ -n "$GITHUB_USER" ]; then
  TOKEN="$(keychain_token "$GITHUB_USER")"
  if token_works; then
    GOT_CREDS=1
    ok "已使用记住的账号：$GITHUB_USER"
  else
    TOKEN=""
  fi
fi

if [ "$GOT_CREDS" = "0" ]; then
  say "第一次运行需要配置一次 GitHub 访问方式。"
  say "推荐做法：打开 https://github.com/settings/tokens/new?scopes=repo&description=Upload-to-GitHub"
  say "勾选 repo 权限后生成令牌，把它粘贴到下面（只会保存在本机 macOS 钥匙串里）。"
  say ""

  if [ -z "$GITHUB_USER" ]; then
    while :; do
      ask_text "GitHub 用户名" "" GITHUB_USER
      [ -n "$GITHUB_USER" ] && break
      warn "用户名不能为空。"
    done
  fi

  attempts=0
  while :; do
    ask_secret "GitHub 访问令牌（粘贴后回车，屏幕不会显示）: " TOKEN
    if [ -z "$TOKEN" ]; then
      warn "令牌不能为空。"
      continue
    fi

    api_request GET /user
    case "$HTTP_CODE" in
      200)
        api_login="$(api_login_field)"
        if [ -n "$api_login" ] && [ "$api_login" != "$GITHUB_USER" ]; then
          warn "令牌实际属于账号 ${api_login}，已按该账号继续。"
          GITHUB_USER="$api_login"
        fi
        break
        ;;
      401)
        attempts=$((attempts + 1))
        [ "$attempts" -ge 3 ] && die "连续 3 次令牌验证失败，请确认令牌复制完整且未过期。"
        warn "令牌无效或已过期，请重新粘贴。"
        TOKEN=""
        ;;
      000)
        die "连不上 GitHub。请确认网络可用；如果平时需要代理上网，请先在终端里设置 https_proxy 后再运行本脚本。"
        ;;
      *)
        die "GitHub 返回 HTTP ${HTTP_CODE}：$(api_error_message)"
        ;;
    esac
  done

  save_config >/dev/null 2>&1 || true
  if keychain_save_token "$GITHUB_USER" "$TOKEN"; then
    ok "登录信息已保存到 macOS 钥匙串，下次双击就不用再填了。"
  else
    warn "令牌没能写入钥匙串，下次运行需要重新输入。"
  fi
fi

# ---- 第 2 步：确定要推到哪个仓库 ----
OWNER=""
REPO=""
BRANCH=""
FROM_EXISTING="0"
FROM_MEMORY="0"
NEW_REPO="0"
origin_url=""

IN_GIT=0
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$TOPLEVEL" ] && [ "$TOPLEVEL" = "$FOLDER" ]; then
  IN_GIT=1
fi

if [ "$IN_GIT" = "1" ]; then
  BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
fi

if [ -n "$origin_url" ]; then
  parsed="$(parse_owner_repo "$origin_url")"
  # 只认 “owner/repo” 这种形状，其他地址（本地路径等）忽略
  case "$parsed" in
    *:*|*/*/*) : ;;
    */*)
      OWNER="${parsed%%/*}"
      REPO="${parsed#*/}"
      FROM_EXISTING="1"
      say "检测到文件夹里已有 git 仓库，沿用远程仓库：$OWNER/$REPO"
      ;;
  esac
fi

if [ -z "$REPO" ]; then
  remembered="$(recall_repo)"
  case "$remembered" in
    */*)
      OWNER="${remembered%%/*}"
      REPO="${remembered#*/}"
      FROM_MEMORY="1"
      say "沿用上次使用过的仓库：$OWNER/$REPO"
      ;;
  esac
fi

if [ -z "$REPO" ]; then
  OWNER="$GITHUB_USER"
  REPO="$(auto_repo_name "$FOLDER_NAME")"
  if has_non_ascii "$FOLDER_NAME"; then
    say "文件夹名是中文，自动取仓库名：$REPO"
  fi
fi

while :; do
  api_request GET "/repos/$OWNER/$REPO"

  if [ "$HTTP_CODE" = "200" ]; then
    if [ "$(api_json_bool private)" = "true" ]; then
      warn "这个仓库是私有的，在线预览地址打开会是 404。想公开可以在仓库 Settings 里改。"
    fi
    if [ "$FROM_EXISTING" != "1" ] && [ "$FROM_MEMORY" != "1" ]; then
      say "GitHub 上已经有同名仓库，直接用它：${OWNER}/${REPO}"
    fi
    break
  fi

  if [ "$HTTP_CODE" = "404" ]; then
    say "GitHub 上还没有 ${OWNER}/${REPO}，正在创建 ..."
    # 一律建公开仓库：私有仓库没法用在线预览
    REPO_VISIBILITY="public"
    api_request POST /user/repos "{\"name\":\"$REPO\",\"private\":false,\"auto_init\":false}"
    case "$HTTP_CODE" in
      201)
        ok "已创建仓库 ${OWNER}/${REPO}（${REPO_VISIBILITY}）"
        NEW_REPO="1"
        break
        ;;
      422)
        die "仓库名 $REPO 不可用：$(api_error_message)"
        ;;
      403|401)
        die "当前账号没有创建仓库的权限：$(api_error_message)。请改用带 repo 权限的令牌，或先在 GitHub 网站上手动建好仓库。"
        ;;
      *)
        die "创建仓库失败（HTTP ${HTTP_CODE}）：$(api_error_message)"
        ;;
    esac
  fi

  if [ "$HTTP_CODE" = "000" ]; then
    die "连不上 GitHub，请检查网络后重试。"
  fi

  die "查询仓库时出错（HTTP ${HTTP_CODE}）：$(api_error_message)"
done

remember_repo "$OWNER/$REPO"

REPO_URL="$REMOTE_BASE/$OWNER/$REPO.git"
REPO_WEB_URL="https://$GITHUB_HOST/$OWNER/$REPO"
REPO_PATH="$OWNER/$REPO"

# ---- 第 3 步：准备本地仓库 ----
if [ "$IN_GIT" = "0" ]; then
  git init -q || die "初始化本地 Git 仓库失败。"
  if [ -z "$BRANCH" ]; then
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  fi
  ok "已把这个文件夹初始化为本地 Git 仓库"
fi

if [ -z "$BRANCH" ]; then
  BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi
if [ -z "$BRANCH" ]; then
  BRANCH="main"
  git checkout -q -b main 2>/dev/null || true
fi

if ! git config user.name >/dev/null 2>&1; then
  git config user.name "$GITHUB_USER"
fi
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "$GITHUB_USER@users.noreply.github.com"
fi

EXCLUDE_FILE="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"
if [ -n "$EXCLUDE_FILE" ]; then
  mkdir -p "$(dirname "$EXCLUDE_FILE")" 2>/dev/null || true
  touch "$EXCLUDE_FILE" 2>/dev/null || true
  if [ -f "$EXCLUDE_FILE" ] && ! grep -qx '.DS_Store' "$EXCLUDE_FILE" 2>/dev/null; then
    printf '\n.DS_Store\n' >> "$EXCLUDE_FILE"
  fi
fi

BIG_FILES="$(find . -path './.git' -prune -o -type f -size +95M -print 2>/dev/null)"
if [ -n "$BIG_FILES" ]; then
  warn "下面这些文件超过 95MB，GitHub 会拒绝上传："
  printf '%s\n' "$BIG_FILES"
  die "请先压缩或移除它们，然后重新双击本脚本。"
fi

TOTAL_KB="$(du -sk "$FOLDER" 2>/dev/null | awk '{print $1}')"
if [ -n "$TOTAL_KB" ] && [ "$TOTAL_KB" -gt 524288 ] 2>/dev/null; then
  TOTAL_HUMAN="$(awk -v kb="$TOTAL_KB" 'BEGIN { printf "%.2f", kb/1048576 }')"
  warn "这个文件夹大约 ${TOTAL_HUMAN} GB，超过了 GitHub 建议的仓库体积。"
  ask_yes "仍然继续上传吗？" || die "已取消，没有做任何上传。"
fi

if [ -f .gitignore ]; then
  warn "文件夹里有 .gitignore，被它排除掉的文件不会上传。"
fi

add_output="$(git add -A 2>&1)" || die "git add 失败，请检查文件权限。"
case "$add_output" in
  *"embedded git repositor"*)
    warn "有子文件夹本身是 git 仓库，那些子文件夹内部的文件不会被上传。"
    ;;
esac

if git diff --cached --quiet; then
  say "这次没有新的文件改动。"
else
  git commit -q -m "更新于 $(date '+%Y-%m-%d %H:%M:%S')" || die "git commit 失败。"
  ok "已记录本次改动"
fi

# ---- 第 4 步：推送 ----
USE_TOKEN_PUSH=1
REMOTE_TO_USE="$REPO_URL"

if [ -n "$origin_url" ]; then
  case "$origin_url" in
    git@*|ssh://*)
      # 保留用户原本的 SSH 地址，用那把钥匙推送
      if [ "$(parse_owner_repo "$origin_url")" = "$REPO_PATH" ]; then
        REMOTE_TO_USE="$origin_url"
        USE_TOKEN_PUSH=0
      fi
      ;;
  esac
fi

case "$REMOTE_TO_USE" in
  https://*) : ;;
  *) USE_TOKEN_PUSH=0 ;;
esac

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_TO_USE" || die "设置远程仓库地址失败。"
else
  git remote add origin "$REMOTE_TO_USE" || die "添加远程仓库失败。"
fi

say ""
say "正在上传到 $REPO_PATH ..."

if [ "$USE_TOKEN_PUSH" = "1" ]; then
  # 国内网络下 HTTP/2 经常报 “Error in the HTTP2 framing layer”，统一改用 HTTP/1.1
  git config http.version HTTP/1.1 >/dev/null 2>&1 || true
  git config http.postBuffer 524288000 >/dev/null 2>&1 || true

  EXISTING_PROXY="$(git config http.proxy 2>/dev/null || true)"
  if [ -n "$EXISTING_PROXY" ] && curl -sS -o /dev/null -m 6 -x "$EXISTING_PROXY" 'https://github.com/' >/dev/null 2>&1; then
    say "沿用上次的代理 ${EXISTING_PROXY}"
  elif curl -sS -o /dev/null -m 6 'https://github.com/' >/dev/null 2>&1; then
    # 直连没问题：清掉以前可能留下的代理设置，避免代理关掉后反而连不上
    git config --unset http.proxy >/dev/null 2>&1 || true
  else
    warn "直连 github.com 不通（可能被网络拦了），正在找本机代理 ..."
    FOUND_PROXY="$(detect_http_proxy || true)"
    if [ -n "$FOUND_PROXY" ]; then
      git config http.proxy "$FOUND_PROXY" >/dev/null 2>&1 || true
      ok "找到可用代理 ${FOUND_PROXY}，改用它上传"
    else
      warn "没找到可用的本机代理，先直接试一次。"
    fi
  fi
fi

do_push() { # do_push [--force]
  local mode="${1:-}"
  if [ "$USE_TOKEN_PUSH" = "1" ]; then
    if ! git_askpass_setup; then
      push_status=1
      push_log="准备登录凭据失败"
      return 1
    fi
  fi
  if [ -n "$mode" ]; then
    push_log="$(LC_ALL=C git push --porcelain "$mode" origin "$BRANCH" 2>&1)"
  else
    push_log="$(LC_ALL=C git push --porcelain origin "$BRANCH" 2>&1)"
  fi
  push_status=$?
  git_askpass_cleanup
  return 0
}

attempt=0
while :; do
  attempt=$((attempt + 1))
  do_push
  [ "$push_status" -eq 0 ] && break

  case "$push_log" in
    *"Authentication failed"*|*"Invalid username or password"*|*"support for password authentication"*|*"Password authentication"*)
      die "GitHub 认证失败。请删除钥匙串里的「${KEYCHAIN_SERVICE}」条目后重新运行本脚本，或在终端执行 gh auth login。"
      ;;
  esac

  if is_network_error "$push_log" && [ "$attempt" -lt 3 ]; then
    warn "网络中断了（第 ${attempt} 次），3 秒后自动重试 ..."
    sleep 3
    continue
  fi
  break
done

# HTTPS 完全走不通时，自动改走 GitHub 的 443 端口 SSH 通道
if [ "$push_status" -ne 0 ] && [ "$USE_TOKEN_PUSH" = "1" ] && is_network_error "$push_log"; then
  if ssh_over_443_works; then
    warn "github.com 直连不通，自动改用 ssh.github.com:443 通道。"
    REMOTE_TO_USE="ssh://git@ssh.github.com:443/${REPO_PATH}.git"
    USE_TOKEN_PUSH=0
    git remote set-url origin "$REMOTE_TO_USE" >/dev/null 2>&1 || true
    do_push
    if [ "$push_status" -ne 0 ] && is_network_error "$push_log"; then
      sleep 3
      do_push
    fi
    if [ "$push_status" -eq 0 ]; then
      ok "已通过 SSH 通道上传成功（以后再双击会自动走这个通道）"
    fi
  fi
fi

if [ "$push_status" -ne 0 ]; then
  case "$push_log" in
    *"[rejected]"*|*"non-fast-forward"*|*"fetch first"*|*"remote contains work"*)
      warn "远程仓库里已经有其他提交，普通上传被拒绝。"
      if ask_yes "要用本地文件夹的内容覆盖远程吗？（远程多出来的提交会丢失）"; then
        do_push --force
        if [ "$push_status" -ne 0 ] && is_network_error "$push_log"; then
          warn "网络中断了，3 秒后自动重试 ..."
          sleep 3
          do_push --force
        fi
        [ "$push_status" -eq 0 ] || die "仍然推送失败：$push_log"
      else
        die "已取消，远程仓库没有变化。"
      fi
      ;;
    *"Authentication failed"*|*"Invalid username or password"*|*"Password authentication"*|*"support for password authentication"*)
      die "GitHub 认证失败。请删除钥匙串里的「${KEYCHAIN_SERVICE}」条目后重新运行本脚本，或在终端执行 gh auth login。"
      ;;
    *"Could not resolve host"*|*"Connection timed out"*|*"Failed to connect"*|*"HTTP2 framing layer"*|*"RPC failed"*|*"unable to access"*)
      die "连不上 GitHub 的 Git 通道（你的网络把 github.com 拦了）。两个办法，任选一个：

  1) 有代理的话：先在终端里执行 export https_proxy=http://127.0.0.1:端口 再双击本脚本；

  2) 配置一次 SSH 密钥（推荐，之后一直有效）：
     ssh-keygen -t ed25519 -C \"你的邮箱\" -f ~/.ssh/id_ed25519
     cat ~/.ssh/id_ed25519.pub | pbcopy
     然后打开 https://github.com/settings/keys 粘贴并保存，再双击本脚本。

原始错误：${push_log}"
      ;;
    *)
      die "推送失败：$push_log"
      ;;
  esac
fi

git config "branch.$BRANCH.remote" origin >/dev/null 2>&1 || true
git config "branch.$BRANCH.merge" "refs/heads/$BRANCH" >/dev/null 2>&1 || true

ok "文件已经上传到 $REPO_WEB_URL"

# ---- 第 5 步：HTML 在线预览 ----
HTML_LIST="$(find . -path './.git' -prune -o -type f \( -iname '*.html' -o -iname '*.htm' \) -print 2>/dev/null \
  | sed 's#^\./##' | LC_ALL=C sort)"

say ""
say "=============================================="

if [ -z "$HTML_LIST" ]; then
  say "这个文件夹里没有 HTML 文件，所以没有在线预览地址。"
  say "仓库地址：$REPO_WEB_URL"
  say "=============================================="
  pause
  exit 0
fi

if [ "$REPO" = "$OWNER.github.io" ]; then
  PAGES_BASE="https://$OWNER.github.io"
else
  PAGES_BASE="https://$OWNER.github.io/$REPO"
fi

enable_pages() {
  PAGES_OK=0
  api_request POST "/repos/$REPO_PATH/pages" "{\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}"
  case "$HTTP_CODE" in
    201) PAGES_OK=1 ;;
    409)
      api_request PUT "/repos/$REPO_PATH/pages" "{\"source\":{\"branch\":\"$BRANCH\",\"path\":\"/\"}}"
      case "$HTTP_CODE" in
        204|200) PAGES_OK=1 ;;
      esac
      ;;
  esac
}

enable_pages
if [ "$PAGES_OK" = "0" ] && [ "$NEW_REPO" = "1" ]; then
  # 刚建好的仓库偶尔还没准备好，等一下再试一次
  sleep 3
  enable_pages
fi

if [ "$PAGES_OK" = "1" ]; then
  say "已开启 GitHub Pages，正在等待它生成（最多约 25 秒）..."
  pages_ready=0
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    pages_code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$PAGES_BASE/" 2>/dev/null || true)"
    if [ "$pages_code" = "200" ]; then
      pages_ready=1
      break
    fi
    sleep 5
  done
else
  warn "没能开启 GitHub Pages（可能是私有仓库或令牌权限不足），下面给你即时可用的预览地址。"
fi

FIRST_LINK=""
INDEX=0

say ""
say "HTML 在线预览地址："
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  INDEX=$((INDEX + 1))
  enc="$(url_encode_path "$rel")"
  instant="https://raw.githack.com/$REPO_PATH/$BRANCH/$enc"

  case "$(basename -- "$rel")" in
    index.html|index.htm) pages_rel="$(dirname -- "$rel")"; [ "$pages_rel" = "." ] && pages_rel="" ;;
    *) pages_rel="$rel" ;;
  esac
  case "$pages_rel" in
    "") pages_url="$PAGES_BASE/" ;;
    *) pages_url="$PAGES_BASE/$(url_encode_path "$pages_rel")" ;;
  esac

  say ""
  say "$INDEX) $rel"
  say "   即时预览（推荐）：$instant"
  if [ "$PAGES_OK" = "1" ]; then
    if [ "$pages_ready" = "1" ]; then
      say "   GitHub Pages：   $pages_url"
    else
      say "   GitHub Pages：   $pages_url  （首次生成可能要等一两分钟）"
    fi
  fi

  if [ -z "$FIRST_LINK" ]; then
    if [ "$PAGES_OK" = "1" ] && [ "$pages_ready" = "1" ]; then
      FIRST_LINK="$pages_url"
    else
      FIRST_LINK="$instant"
    fi
  fi
done <<HTML_EOF
$HTML_LIST
HTML_EOF

say ""
say "仓库地址：$REPO_WEB_URL"
say "=============================================="

if [ -n "$FIRST_LINK" ]; then
  printf '%s' "$FIRST_LINK" | pbcopy 2>/dev/null || true
  say "预览地址已经复制到剪贴板，正在用浏览器打开 ..."
  open "$FIRST_LINK" >/dev/null 2>&1 || true
fi

pause
exit 0
