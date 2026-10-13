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
  REPO="$(slugify "$FOLDER_NAME")"
  if [ -z "$REPO" ] || has_non_ascii "$FOLDER_NAME"; then
    say "文件夹名「${FOLDER_NAME}」不能直接作为仓库名，请取一个英文仓库名。"
    if [ -n "$REPO" ]; then
      say "直接按回车就用：$REPO"
    fi
    while :; do
      ask_text "仓库名" "$REPO" REPO
      REPO="$(slugify "$REPO")"
      [ -n "$REPO" ] && break
      warn "仓库名只能包含英文字母、数字、- _ . ，请重新输入。"
    done
  fi
fi

while :; do
  api_request GET "/repos/$OWNER/$REPO"

  if [ "$HTTP_CODE" = "200" ]; then
    if [ "$FROM_EXISTING" = "1" ] || [ "$FROM_MEMORY" = "1" ]; then
      break
    fi
    warn "GitHub 上已经有一个同名仓库：$OWNER/$REPO"
    if ask_yes "要把这个文件夹的内容推送上去吗？"; then
      break
    fi
    REPO=""
    while [ -z "$REPO" ]; do
      ask_text "请换一个仓库名" "" REPO
      REPO="$(slugify "$REPO")"
    done
    continue
  fi

  if [ "$HTTP_CODE" = "404" ]; then
    say "GitHub 上还没有 ${OWNER}/${REPO}，正在创建 ..."
    if [ "$VISIBILITY_KNOWN" = "0" ]; then
      say "公开仓库才能生成在线预览地址；私有仓库只有你自己登录 GitHub 才能看。"
      while :; do
        ask_text "输入 1 = 公开（可在线预览），2 = 私有" "1" vis_choice
        case "$vis_choice" in
          1|gongkai|public) REPO_VISIBILITY="public"; break ;;
          2|siyou|private) REPO_VISIBILITY="private"; break ;;
          *) warn "请输入 1 或 2。" ;;
        esac
      done
      VISIBILITY_KNOWN=1
      save_config >/dev/null 2>&1 || true
    fi
    if [ "$REPO_VISIBILITY" = "private" ]; then
      is_private="true"
    else
      is_private="false"
    fi
    api_request POST /user/repos "{\"name\":\"$REPO\",\"private\":$is_private,\"auto_init\":false}"
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
  git_askpass_setup || die "准备凭据失败。"
fi

push_log="$(git push --porcelain origin "$BRANCH" 2>&1)"
push_status=$?
git_askpass_cleanup

if [ "$push_status" -ne 0 ]; then
  case "$push_log" in
    *"[rejected]"*|*"non-fast-forward"*|*"fetch first"*|*"remote contains work"*)
      warn "远程仓库里已经有其他提交，普通上传被拒绝。"
      if ask_yes "要用本地文件夹的内容覆盖远程吗？（远程多出来的提交会丢失）"; then
        if [ "$USE_TOKEN_PUSH" = "1" ]; then git_askpass_setup || true; fi
        push_log="$(git push --porcelain --force origin "$BRANCH" 2>&1)"
        push_status=$?
        git_askpass_cleanup
        [ "$push_status" -eq 0 ] || die "仍然推送失败：$push_log"
      else
        die "已取消，远程仓库没有变化。"
      fi
      ;;
    *"Authentication failed"*|*"Invalid username or password"*|*"Password authentication"*|*"support for password authentication"*)
      die "GitHub 认证失败。请删除钥匙串里的「${KEYCHAIN_SERVICE}」条目后重新运行本脚本，或在终端执行 gh auth login。"
      ;;
    *"Could not resolve host"*|*"Connection timed out"*|*"Failed to connect"*)
      die "连不上 GitHub。请检查网络或代理设置后重试。"
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
