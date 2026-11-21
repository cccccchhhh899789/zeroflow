#!/usr/bin/env bash
set -euo pipefail

# 本地复现 .github/workflows/build.yml 的 build job：按架构分别编 Release 包，
# 然后把 .app 推到 hellolio/zeroflow 的 Zeroflow/dist/<arch>/，再打 tag 触发
# 该仓库的 workflow 去打包 DMG 并发布 Release。
#
#   ./build_all_archs.sh -v 1.6.1               # 构建 + 推 app + 打 tag v1.6.1
#   ./build_all_archs.sh -v 1.6.1 --no-push     # 只本地构建，不推不 tag
#   ./build_all_archs.sh -v 1.6.1 -a arm64      # 只构建/推送一个架构
#   ./build_all_archs.sh --clean -v 1.6.1       # 先清掉 build-release/
#
# 本地产物：dist/<arch>/Zeroflow.app
# 远端路径：Zeroflow/dist/<arch>/Zeroflow.app（main 分支）
#
# 流程分工：本地只负责编译出带 Team 签名的 .app；DMG 由 zeroflow 仓库的
# build.yml 在 tag 触发时用这些预置 app 打包并挂到 Release 上。这样 CI 不再
# 重复编译，本地编完即可发布。
#
# 注意：.app 是二进制目录，进了 git 就永久留在历史里，仓库会随版本数变大。
#
# 与 CI 的差异：签名走 Config/Local.xcconfig 里的 DEVELOPMENT_TEAM（自动签名 +
# -allowProvisioningUpdates 让 FinderSync 的 App Group 自动生成），不导入临时
# keychain。缺 Local.xcconfig 时回退 ad-hoc——能编译，但扩展没有 App Group 写
# 权限，「访达右键打开终端」会静默失败（PITFALLS_DEV.md DEV-018）。

cd "$(dirname "$0")"

PROJECT="Zeroflow.xcodeproj"
SCHEME="Zeroflow"
CONFIG="Release"
APP_NAME="Zeroflow"
OUT_DIR="dist"
BUILD_ROOT="build-release"
RELEASE_REPO="hellolio/zeroflow"
APP_SUBDIR="Zeroflow/dist"

ARCHS="arm64 x86_64"
VERSION=""
VERSION_EXPLICIT=0
DO_CLEAN=0
DO_PUSH=1

usage() {
  cat <<'EOF'
用法: ./build_all_archs.sh -v <版本> [选项]

  -v, --version <版本>  必需（--no-push 时可省）。如 1.6.1 或 v1.6.1，
                        用于 MARKETING_VERSION 与 tag 名
  -a, --archs <列表>    要构建的架构，空格分隔（默认 "arm64 x86_64"）
  -o, --out <目录>      本地产物目录（默认 dist）
      --repo <owner/repo>  覆盖推送目标（默认 hellolio/zeroflow）
      --no-push         只构建，不推送、不打 tag
      --clean           构建前清掉 build-release/
  -h, --help            显示本帮助

推送目标: <repo>/Zeroflow/dist/<arch>/Zeroflow.app + tag v<版本>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--archs)
      ARCHS="${2:-}"
      [[ -n "$ARCHS" ]] || { echo "错误：--archs 需要一个值" >&2; exit 1; }
      shift 2
      ;;
    -v|--version)
      VERSION="${2:-}"
      [[ -n "$VERSION" ]] || { echo "错误：--version 需要一个值" >&2; exit 1; }
      VERSION_EXPLICIT=1
      shift 2
      ;;
    -o|--out)
      OUT_DIR="${2:-}"
      [[ -n "$OUT_DIR" ]] || { echo "错误：--out 需要一个目录" >&2; exit 1; }
      shift 2
      ;;
    --repo)
      RELEASE_REPO="${2:-}"
      [[ -n "$RELEASE_REPO" ]] || { echo "错误：--repo 需要 owner/repo" >&2; exit 1; }
      shift 2
      ;;
    --no-push) DO_PUSH=0; shift ;;
    --clean) DO_CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数 $1" >&2; usage >&2; exit 1 ;;
  esac
done

# 版本号：接受 v1.6.1 / 1.6.1 两种写法。要推送就必须显式给，否则 tag 无从命名。
if [[ -n "$VERSION" ]]; then
  VERSION="${VERSION#v}"
fi
if [[ -z "$VERSION" ]]; then
  if [[ "$DO_PUSH" == 1 ]]; then
    echo "错误：要推送并打 tag，必须用 -v 指定版本号（如 -v 1.6.1）；只构建请加 --no-push" >&2
    exit 1
  fi
  VERSION="0.0.0-dev"
  echo "提示：未指定版本号，MARKETING_VERSION 用 ${VERSION}"
fi

if [[ "$DO_PUSH" == 1 && "$VERSION" == "0.0.0-dev" ]]; then
  echo "错误：不能推送 dev 版本，请用 -v 指定正式版本号" >&2
  exit 1
fi

# 签名配置：有 Team 就自动签名，否则 ad-hoc 回退。
SIGN_ARGS=()
SIGN_MODE="ad-hoc"
TEAM=""
if [[ -f "Config/Local.xcconfig" ]]; then
  TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' Config/Local.xcconfig | head -n 1)"
fi
if [[ -n "$TEAM" && "$TEAM" != "YOUR_TEAM_ID_HERE" ]]; then
  SIGN_MODE="team ($TEAM)"
  SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM")
else
  echo "警告：Config/Local.xcconfig 里没有有效的 DEVELOPMENT_TEAM，回退 ad-hoc 签名。" >&2
  echo "      ad-hoc 包的 FinderSync 扩展无 App Group 写权限（DEV-018），仅够编译检查。" >&2
  echo "      修法：cp Config/Local.xcconfig.example Config/Local.xcconfig 并填入 Team ID。" >&2
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

if [[ "$DO_CLEAN" == 1 ]]; then
  echo "==> 清理 $BUILD_ROOT"
  rm -rf "$BUILD_ROOT"
fi

mkdir -p "$OUT_DIR"

# 每个架构用独立 derivedDataPath：共用同一个目录时后一次构建会复用/覆盖
# Products/Release，容易拿到上一个架构的产物（CI 也靠 matrix 天然隔离）。
# 用空格分隔的字符串而不是数组：macOS 自带 bash 3.2 在 set -u 下展开空数组会报错。
FAILED_ARCHS=""
BUILT_ARCHS=""

for arch in $ARCHS; do
  echo
  echo "==> [$arch] 开始构建（$CONFIG, MARKETING_VERSION=$VERSION, 签名 ${SIGN_MODE}）"
  DD="$BUILD_ROOT/$arch"

  if ! xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -derivedDataPath "$DD" \
      -allowProvisioningUpdates \
      "${SIGN_ARGS[@]}" \
      MARKETING_VERSION="$VERSION" \
      ARCHS="$arch" ONLY_ACTIVE_ARCH=NO \
      -quiet \
      build; then
    echo "错误：[$arch] 构建失败" >&2
    FAILED_ARCHS="$FAILED_ARCHS $arch"
    continue
  fi

  # 产物路径会漂移（可能落到 ArchiveIntermediates），按 CI 的做法先试常规路径再 find。
  APP="$DD/Build/Products/$CONFIG/$APP_NAME.app"
  if [[ ! -d "$APP" ]]; then
    APP="$(find "$DD/Build" -type d -name "$APP_NAME.app" -path "*$CONFIG*" 2>/dev/null | head -n 1)"
  fi
  if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
    echo "错误：[$arch] 在 $DD 下找不到 $APP_NAME.app" >&2
    FAILED_ARCHS="$FAILED_ARCHS $arch"
    continue
  fi

  # 逐个 Mach-O 核对架构：ARCHS 没生效时会静默产出本机架构的二进制，
  # 包名对、内容不对，只有 lipo 能查出来。
  normalize() { echo "$1" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ *$//'; }
  expected_n="$(normalize "$arch")"
  arch_ok=1

  check_bin() {
    local bin="$1"
    if [[ ! -f "$bin" ]]; then
      echo "错误：[$arch] 缺少可执行文件：$bin" >&2
      return 1
    fi
    local actual
    actual="$(lipo -archs "$bin")"
    if [[ "$(normalize "$actual")" != "$expected_n" ]]; then
      echo "错误：[$arch] $bin 架构不符：期望 '$expected_n'，实际 '$actual'" >&2
      return 1
    fi
    echo "    $(basename "$bin"): $actual"
  }

  check_bin "$APP/Contents/MacOS/$APP_NAME" || arch_ok=0
  if [[ -d "$APP/Contents/PlugIns" ]]; then
    for appex in "$APP"/Contents/PlugIns/*.appex; do
      [[ -d "$appex" ]] || continue
      check_bin "$appex/Contents/MacOS/$(basename "$appex" .appex)" || arch_ok=0
    done
  fi
  if [[ "$arch_ok" != 1 ]]; then
    FAILED_ARCHS="$FAILED_ARCHS $arch"
    continue
  fi

  # 校验签名完整性（ad-hoc 也验，只是没有 TeamIdentifier 可对）。
  if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "错误：[$arch] 签名校验失败：$APP" >&2
    FAILED_ARCHS="$FAILED_ARCHS $arch"
    continue
  fi
  if [[ -n "$TEAM" && "$SIGN_MODE" != "ad-hoc" ]]; then
    # 注意：不要写成 `codesign ... | grep -q`——grep -q 命中即退出会关掉管道，
    # codesign 收到 SIGPIPE(141)，在 set -o pipefail 下整条管道判为失败，
    # 于是签名明明正确却被报成「未按 Team 签名」。先收进变量再匹配。
    SIG_INFO="$(codesign -dv "$APP/Contents/PlugIns/FinderSyncExtension.appex" 2>&1 || true)"
    if ! grep -q "TeamIdentifier=$TEAM" <<<"$SIG_INFO"; then
      echo "错误：[$arch] appex 未按 Team $TEAM 签名，扩展在沙盒下无法写 App Group" >&2
      FAILED_ARCHS="$FAILED_ARCHS $arch"
      continue
    fi
  fi

  # 归档到 dist/<arch>/：用 ditto 保留扩展属性与 _CodeSignature，别用 cp -R。
  DEST="$OUT_DIR/$arch"
  rm -rf "$DEST"
  mkdir -p "$DEST"
  ditto "$APP" "$DEST/$APP_NAME.app"
  echo "    app: $DEST/$APP_NAME.app"
  BUILT_ARCHS="$BUILT_ARCHS $arch"
done

echo
echo "========== 结果 =========="
echo "版本: $VERSION   签名: $SIGN_MODE"
for a in $BUILT_ARCHS; do
  echo "  成功 $a -> $OUT_DIR/$a/$APP_NAME.app"
done
if [[ -n "${FAILED_ARCHS// /}" ]]; then
  for a in $FAILED_ARCHS; do echo "  失败 $a" >&2; done
  exit 1
fi

if [[ "$DO_PUSH" != 1 ]]; then
  echo "完成（--no-push）。要推送到 $RELEASE_REPO 并打 tag，去掉 --no-push。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 推送 .app 到目标仓库 main，再打 tag 触发那边的 workflow 出 DMG + Release
# ---------------------------------------------------------------------------
# 不直接给当前仓库加 remote 再 push：当前分支是 zeroflow-core 的 main，
# 一次 `git push <remote> main` 会把本地所有提交一起带过去。改成浅克隆目标仓库
# 到临时目录，只提交 app，push 范围严格可控。
PUSH_TMP=""
cleanup_push_tmp() {
  if [[ -n "$PUSH_TMP" && -d "$PUSH_TMP" ]]; then
    rm -rf "$PUSH_TMP"
  fi
}
trap cleanup_push_tmp EXIT

for a in $BUILT_ARCHS; do
  if [[ ! -d "$OUT_DIR/$a/$APP_NAME.app" ]]; then
    echo "错误：缺少 $OUT_DIR/$a/$APP_NAME.app，中止推送" >&2
    exit 1
  fi
done

PUSH_TMP="$(mktemp -d)"
echo
echo "==> 克隆 $RELEASE_REPO (main) 到临时目录"
git clone --depth 1 --branch main "https://github.com/$RELEASE_REPO.git" "$PUSH_TMP/repo" --quiet

for a in $BUILT_ARCHS; do
  rm -rf "$PUSH_TMP/repo/$APP_SUBDIR/$a/$APP_NAME.app"
  mkdir -p "$PUSH_TMP/repo/$APP_SUBDIR/$a"
  ditto "$OUT_DIR/$a/$APP_NAME.app" "$PUSH_TMP/repo/$APP_SUBDIR/$a/$APP_NAME.app"
  echo "    写入 $APP_SUBDIR/$a/$APP_NAME.app"
done

# -A 让被删掉/替换的文件也进暂存区；-f 是因为目标仓库 .gitignore 忽略 dist/。
(
  cd "$PUSH_TMP/repo"
  git add -A -f "$APP_SUBDIR"
)

if git -C "$PUSH_TMP/repo" diff --cached --quiet; then
  echo "    $APP_SUBDIR/ 与远端完全一致，跳过提交"
else
  git -C "$PUSH_TMP/repo" commit --quiet -m "build: Zeroflow v$VERSION app ($(echo $BUILT_ARCHS | tr ' ' ','))"
  echo "==> 推送 main"
  PUSH_ERR="$(mktemp)"
  if ! git -C "$PUSH_TMP/repo" push --quiet origin main 2>"$PUSH_ERR"; then
    echo "错误：推送 $RELEASE_REPO 的 main 失败：" >&2
    sed 's/^/    /' "$PUSH_ERR" >&2
    if grep -q "GH013" "$PUSH_ERR"; then
      cat >&2 <<'MSG'

    main 上有 ruleset（required status checks，无 bypass），直推新 commit 必被拒。
    可选做法：
      1. 走 PR：把这次提交推到临时分支，开 PR 等 CI 检查通过后合并；
      2. 临时把 ruleset 置为 disabled，推完恢复；
      3. 在 ruleset 里给当前账号加 bypass。
MSG
    fi
    rm -f "$PUSH_ERR"
    exit 1
  fi
  rm -f "$PUSH_ERR"
  echo "    main 已更新"
fi

# tag 必须打在这次提交上：CI 在 tag 上 checkout 后才找得到刚推上去的 app。
TAG="v$VERSION"
if [[ -n "$(git -C "$PUSH_TMP/repo" ls-remote --tags origin "refs/tags/$TAG")" ]]; then
  echo "错误：tag $TAG 已存在于 ${RELEASE_REPO}，换一个版本号" >&2
  exit 1
fi

git -C "$PUSH_TMP/repo" tag -a "$TAG" -m "Release $TAG"
echo "==> 推送 tag $TAG"
git -C "$PUSH_TMP/repo" push --quiet origin "$TAG"

echo
echo "完成："
echo "  app : https://github.com/$RELEASE_REPO/tree/main/$APP_SUBDIR"
echo "  tag : https://github.com/$RELEASE_REPO/releases/tag/$TAG"
echo "  CI 将被 tag 触发，用上面的 app 打包 DMG 并发布 Release。前往zeroflow查看结果"
