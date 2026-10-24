#!/bin/zsh
# 发布到 GitHub：把工程整理成干净的公开版本，提交、推送，并把安装包 zip 放到 Release 里。
# 用法：tools/publish_github.sh "这次更新了什么"
# 公开仓库放在 ../aoligei-appletv（单独的 git 仓库），不带你的团队编号、宣传图和编译产物。
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REPO_NAME="aoligei-appletv"
PUB="$ROOT/../$REPO_NAME"
MSG="${1:-更新}"
TAG="v$(date +%Y.%m.%d-%H%M)"

./tools/make_share_zip.sh
ZIP="$ROOT/share/奥利给-AppleTV安装包.zip"

mkdir -p "$PUB"
rsync -a --delete --exclude '.git' --exclude '.DS_Store' --exclude 'xcuserdata' --exclude '*.xcuserstate' \
  --include '/TVBrowser/***' --include '/TVBrowser.xcodeproj/***' --include '/UITests/***' --include '/Tests/***' \
  --include '/tools/' --include '/tools/make_icons.py' --include '/tools/make_share_zip.sh' --include '/tools/publish_github.sh' \
  --include '/tools/icon-source/***' --include '/project.yml' --include '/build-check.sh' --exclude '*' \
  "$ROOT/" "$PUB/"
cp "$ROOT/share/安装到AppleTV.command" "$ROOT/share/使用说明.txt" "$PUB/"
chmod +x "$PUB/安装到AppleTV.command"
mkdir -p "$PUB/docs"
cp "$ROOT/README.md" "$PUB/docs/开发说明.md"
cp "$ROOT/share/github/README.md" "$PUB/README.md"
cp "$ROOT"/share/github/*.png "$PUB/docs/"
cat > "$PUB/.gitignore" <<'EOF'
build/
DerivedData/
xcuserdata/
*.xcuserstate
.DS_Store
安装日志.txt
EOF

# 去掉自己的团队编号（工程文件里有两处）
MY_TEAM=$(sed -n -E 's/.*DEVELOPMENT_TEAM: "([A-Z0-9]{10})".*/\1/p' "$ROOT/project.yml" | head -1)
sed -i '' -E 's/DEVELOPMENT_TEAM = [A-Z0-9]{10};/DEVELOPMENT_TEAM = "";/g; /DevelopmentTeam = [A-Z0-9]{10};/d' "$PUB/TVBrowser.xcodeproj/project.pbxproj"
sed -i '' -E 's/DEVELOPMENT_TEAM: "[A-Z0-9]{10}"/DEVELOPMENT_TEAM: ""/' "$PUB/project.yml"
if [[ -n "$MY_TEAM" ]] && grep -r -q "$MY_TEAM" "$PUB" --exclude-dir=.git; then
  echo "公开版本里还有团队编号，停止发布" >&2; exit 1
fi

cd "$PUB"
[[ -d .git ]] || { git init -q -b main; }
git add -A
if git diff --cached --quiet; then
  echo "代码没有变化"
else
  git commit -q -m "$MSG"
fi
if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO_NAME" --public --source . --push \
    --description "奥利给：Apple TV 网页浏览器，遥控器光标上网、原生播放器全屏看视频和直播"
else
  git push -q origin main
fi
# Release 附件名只能用英文，中文会被改成点；固定下载地址：/releases/latest/download/aoligei-appletv.zip
ASSET="$(mktemp -d)/aoligei-appletv.zip"
cp "$ZIP" "$ASSET"
gh release create "$TAG" "$ASSET#奥利给-AppleTV安装包.zip" --title "奥利给 $TAG" --notes "$MSG

下载下面的「奥利给-AppleTV安装包.zip」（aoligei-appletv.zip），解压后双击「安装到AppleTV.command」。详细步骤见仓库首页。" --latest
echo "已发布：$(gh repo view --json url -q .url)"
