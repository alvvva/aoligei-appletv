#!/bin/zsh
# 打包「奥利给」分享安装包：share/奥利给-AppleTV安装包.zip
# 包里有：双击安装脚本、中文说明、编译需要的工程和源码（不含你的团队编号、编译产物、测试和宣传图）。
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/share"
STAGE=$(mktemp -d)/奥利给-AppleTV安装包
mkdir -p "$STAGE"

cp "$OUT/安装到AppleTV.command" "$OUT/使用说明.txt" "$STAGE/"
chmod +x "$STAGE/安装到AppleTV.command"
rsync -a --exclude '.DS_Store' --exclude 'xcuserdata' "$ROOT/TVBrowser.xcodeproj" "$STAGE/"
rsync -a --exclude '.DS_Store' "$ROOT/TVBrowser" "$ROOT/UITests" "$STAGE/"

# 去掉你自己的团队编号，朋友会用他自己的
sed -i '' -E 's/DEVELOPMENT_TEAM = [A-Z0-9]{10};/DEVELOPMENT_TEAM = "";/g; /DevelopmentTeam = [A-Z0-9]{10};/d' "$STAGE/TVBrowser.xcodeproj/project.pbxproj"
if grep -q -E '(DEVELOPMENT_TEAM|DevelopmentTeam) = [A-Z0-9]{10};' "$STAGE/TVBrowser.xcodeproj/project.pbxproj"; then
  echo "团队编号没有清理干净" >&2; exit 1
fi

# Gmail、Outlook 会拒收带 .js 的附件（压缩包里的也查），先改名，安装脚本运行时再改回来
for f in "$STAGE"/TVBrowser/Scripts/*.js; do mv "$f" "$f.txt"; done
BLOCKED=$(find "$STAGE" -type f | grep -i -E '\.(js|exe|bat|cmd|com|jar|vbs|ps1|msi|dmg|iso|scr|lnk)$' || true)
if [[ -n "$BLOCKED" ]]; then
  echo "包里还有邮件会拒收的文件：$BLOCKED" >&2; exit 1
fi

rm -f "$OUT/奥利给-AppleTV安装包.zip"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$OUT/奥利给-AppleTV安装包.zip"
rm -rf "$(dirname "$STAGE")"
echo "已生成：$OUT/奥利给-AppleTV安装包.zip ($(du -h "$OUT/奥利给-AppleTV安装包.zip" | cut -f1))"
