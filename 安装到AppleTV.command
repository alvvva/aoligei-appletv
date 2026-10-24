#!/bin/zsh
# 奥利给 —— 一键安装到 Apple TV
# 双击运行即可。第一次会引导你配对电视；以后每 7 天（免费 Apple ID 的签名有效期）再双击一次就能续上，收藏和历史都会保留。
#
# 可选参数（一般用不到）：
#   --check       只检查环境（Xcode、团队、电视），不安装
#   --no-launch   装好后不自动打开
#   --tv "名字"   有多台 Apple TV 时直接指定装到哪一台
# 可选环境变量：BUNDLE_ID=自定义 App 标识

set -u
cd "$(dirname "$0")"
HERE="$(pwd)"
LOG="$HERE/安装日志.txt"
# 邮件附件不让带 .js 文件，打包时改成了 .js.txt，这里改回来
for f in "$HERE"/TVBrowser/Scripts/*.js.txt(N); do mv -f "$f" "${f%.txt}"; done
CHECK_ONLY=0
LAUNCH=1
TV_ARG=""
while (( $# > 0 )); do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --no-launch) LAUNCH=0 ;;
    --tv) shift; TV_ARG="${1:-}" ;;
  esac
  shift
done

TAB=$'\t'
step() { print -P "\n%F{208}%B▶ $1%b%f" }
ok()   { print -P "%F{green}✓ $1%f" }
note() { print -P "%F{244}  $1%f" }
fail() {
  print -P "\n%F{red}%B✗ $1%b%f"
  [[ -n "${2:-}" ]] && print "$2"
  print "\n（详细记录在：$LOG）"
  if [[ -t 0 ]]; then print "按回车键关闭窗口"; read -r _; fi
  exit 1
}
ask() { # 问题 → 读一行输入
  print -n -P "%F{39}$1%f "
  read -r REPLY
}

print -P "%F{208}%B"
print "  ╭──────────────────────────────╮"
print "  │   奥利给 · 安装到 Apple TV    │"
print "  ╰──────────────────────────────╯"
print -P "%b%f"
: > "$LOG"

# ---------- 1. Xcode ----------
step "检查 Xcode"
if [[ "$(xcode-select -p 2>/dev/null)" != *Xcode*.app* ]]; then
  XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
  if [[ -z "$XCODE_APP" ]]; then
    fail "没有找到 Xcode" "请先在 Mac 的 App Store 搜索「Xcode」免费安装（大约 3 GB），装好后打开一次，再双击本文件。"
  fi
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
if ! xcodebuild -version >>"$LOG" 2>&1; then
  open -a Xcode 2>/dev/null
  fail "Xcode 还不能用" "已经帮你打开了 Xcode：第一次打开时会弹出许可协议，点「同意」（Agree），等它装完组件后，再双击本文件。"
fi
ok "$(xcodebuild -version 2>/dev/null | head -1)"
if ! xcodebuild -showsdks 2>/dev/null | grep -q appletvos; then
  step "下载 tvOS 组件（约 4 GB，只需要一次）"
  xcodebuild -downloadPlatform tvOS 2>&1 | tee -a "$LOG" | grep -v -E "^\s*$" | tail -3
  xcodebuild -showsdks 2>/dev/null | grep -q appletvos || fail "tvOS 组件下载失败" "请在 Xcode → Settings → Components 里手动下载 tvOS，然后重试。"
fi
ok "tvOS 开发组件已就绪"

# ---------- 2. 开发团队（Apple ID）----------
step "查找你的 Apple ID 开发团队"
PREFS=~/Library/Preferences/com.apple.dt.Xcode.plist
list_teams() {
  plutil -extract IDEProvisioningTeamByIdentifier json -o - "$PREFS" 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit()
seen = []
for teams in data.values():
    for t in teams:
        if t.get("teamID") and t["teamID"] not in [s[0] for s in seen]:
            seen.append((t["teamID"], t.get("teamName", "")))
for tid, name in seen:
    print(tid + "\t" + name)
'
}
TEAM=""
TEAMS=("${(@f)$(list_teams)}")
TEAMS=(${TEAMS:#})
if (( ${#TEAMS} == 1 )); then
  TEAM="${TEAMS[1]%%${TAB}*}"
elif (( ${#TEAMS} > 1 )); then
  print "找到多个开发团队："
  for i in {1..${#TEAMS}}; do print "  $i) ${TEAMS[$i]#*${TAB}}  (${TEAMS[$i]%%${TAB}*})"; done
  ask "装到哪个团队？输入编号："
  TEAM="${TEAMS[${REPLY:-1}]%%${TAB}*}"
fi
if [[ -z "$TEAM" ]]; then
  # 证书里的 OU 字段就是团队编号
  TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
fi
if [[ -z "$TEAM" ]]; then
  if (( CHECK_ONLY )); then
    note "还没有找到开发团队（需要先在 Xcode 里登录 Apple ID 并选一次 Team）"
  else
    print -P "%F{yellow}还没有找到你的开发团队，需要在 Xcode 里点几下（只需要这一次）：%f"
    print "  1. Xcode 菜单 → Settings → Accounts → 左下角「+」→ Apple ID，登录你的 Apple ID（免费账号就行）"
    print "  2. 回到 Xcode 主窗口：左侧点最上面的蓝色「TVBrowser」→ 中间 TARGETS 里的「TVBrowser」"
    print "     → 顶部「Signing & Capabilities」→ Team 选带「(Personal Team)」的那一项"
    print "  选好后这里会自动继续（最多等 15 分钟）……"
    open "$HERE/TVBrowser.xcodeproj"
    for i in {1..300}; do
      TEAM=$(grep -o -E 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$HERE/TVBrowser.xcodeproj/project.pbxproj" | head -1 | grep -o -E '[A-Z0-9]{10}')
      [[ -n "$TEAM" ]] && break
      sleep 3
    done
    [[ -z "$TEAM" ]] && fail "等了 15 分钟还没选好 Team" "选好后重新双击本文件即可。"
  fi
fi
[[ -n "$TEAM" ]] && ok "开发团队：$TEAM"
BUNDLE_ID="${BUNDLE_ID:-com.${(L)TEAM}.aoligei}"

# ---------- 3. Apple TV ----------
step "查找 Apple TV"
TMPJSON=$(mktemp -t aoligei)
list_tvs() { # 输出：标识<TAB>名字<TAB>是否已配对<TAB>开发者模式
  xcrun devicectl list devices --json-output "$TMPJSON" >/dev/null 2>&1
  /usr/bin/python3 - "$TMPJSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit()
for d in devices:
    hp, cp, dp = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if hp.get("reality") != "physical" or not str(hp.get("productType", "")).startswith("AppleTV"):
        continue
    print("\t".join([hp.get("udid") or d.get("identifier", ""), dp.get("name", "Apple TV"),
                     cp.get("pairingState", ""), str(dp.get("developerModeStatus", ""))]))
PY
}
pick_tv() {
  TVS=("${(@f)$(list_tvs)}"); TVS=(${TVS:#})
  if [[ -n "$TV_ARG" ]]; then TVS=(${(M)TVS:#*${TAB}${TV_ARG}${TAB}*}); fi
  PAIRED=(${(M)TVS:#*${TAB}paired${TAB}*})
}
pick_tv
if (( ${#PAIRED} == 0 )); then
  if (( CHECK_ONLY )); then
    note "还没有配对过的 Apple TV"
  else
    print -P "%F{yellow}这台 Mac 还没有和 Apple TV 配对，先配对一下（只需要这一次）：%f"
    print "  1. 确认 Apple TV 和这台 Mac 连在同一个 Wi-Fi"
    print "  2. 在 Apple TV 上打开：设置 → 遥控器与设备 → 遥控器 App 与设备，停在这个页面"
    print "  正在等电视出现（最多 5 分钟）……"
    NAME=""
    for i in {1..60}; do
      NAME=$( ( dns-sd -B _remotepairing-manual-pairing._tcp local. & P=$!; sleep 5; kill $P ) 2>/dev/null | awk '/ Add /{for(i=7;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""; exit}')
      [[ -n "$NAME" ]] && break
    done
    [[ -z "$NAME" ]] && fail "5 分钟内没有发现处于配对页面的 Apple TV" "请确认电视停在「遥控器 App 与设备」页面、和 Mac 在同一个 Wi-Fi，再双击本文件重试。"
    ok "发现 Apple TV：$NAME"
    print -P "%F{39}电视上会显示一个配对码，请在下面输入后按回车：%f"
    xcrun devicectl manage pair --device "$NAME" --timeout 180 || fail "配对没有成功" "电视上的配对码可能过期了，再双击本文件重试即可。"
    sleep 3
    pick_tv
    (( ${#PAIRED} == 0 )) && fail "配对后还是找不到电视" "请重新双击本文件试一次。"
  fi
fi
UDID=""
if (( ${#PAIRED} == 1 )); then
  CHOSEN="${PAIRED[1]}"
elif (( ${#PAIRED} > 1 )); then
  print "找到多台 Apple TV："
  for i in {1..${#PAIRED}}; do print "  $i) $(print -r -- "${PAIRED[$i]}" | cut -f2)"; done
  ask "装到哪一台？输入编号："
  CHOSEN="${PAIRED[${REPLY:-1}]}"
fi
if [[ -n "${CHOSEN:-}" ]]; then
  UDID=$(print -r -- "$CHOSEN" | cut -f1)
  TVNAME=$(print -r -- "$CHOSEN" | cut -f2)
  DEVMODE=$(print -r -- "$CHOSEN" | cut -f4)
  ok "Apple TV：$TVNAME"
  if [[ "$DEVMODE" == "disabled" ]]; then
    print -P "%F{yellow}这台 Apple TV 还没打开「开发者模式」。请在电视上：设置 → 隐私与安全性 → 开发者模式，打开后按提示重启，再双击本文件。%f"
    (( CHECK_ONLY )) || fail "需要先打开开发者模式"
  fi
fi
rm -f "$TMPJSON"

if (( CHECK_ONLY )); then
  print "\n检查完毕：团队=${TEAM:-无}  App 标识=$BUNDLE_ID  电视=${TVNAME:-无}"
  exit 0
fi

# ---------- 4. 编译、签名、安装 ----------
step "编译并签名（第一次大约需要 1~3 分钟）"
xcodebuild -project TVBrowser.xcodeproj -scheme TVBrowser -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$HERE/build" \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >>"$LOG" 2>&1
if [[ $? -ne 0 ]]; then
  ERR=$(grep -E "error:" "$LOG" | sed 's/^.*error: //' | sort -u | head -3)
  fail "编译或签名失败" "$ERR"$'\n'"常见原因：Xcode 里的 Apple ID 登录过期了（到 Xcode → Settings → Accounts 重新登录），或者免费账号 7 天内新建的 App 太多（等几天再试）。"
fi
APP="$HERE/build/Build/Products/Release-appletvos/TVBrowser.app"
ok "编译完成"

step "安装到 $TVNAME"
xcrun devicectl device install app --device "$UDID" "$APP" >>"$LOG" 2>&1 || fail "安装失败" "请确认电视开着、和 Mac 在同一个 Wi-Fi，然后重试。"
ok "已安装「奥利给」"

if (( LAUNCH )); then
  step "打开奥利给"
  if ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" >>"$LOG" 2>&1; then
    print -P "%F{yellow}自动打开没有成功。第一次安装时 Apple TV 可能要求信任开发者：%f"
    print "  在电视上打开：设置 → 通用 → 设备管理（或 隐私与安全性 → 开发者 App），选中你的 Apple ID → 信任"
    print "  然后在电视主屏幕上找到小狗图标「奥利给」打开即可。"
  else
    ok "已经在电视上打开了"
  fi
fi

EXP=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)
if [[ -n "$EXP" ]]; then
  EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" "+%s" 2>/dev/null)
  LOCAL_EXP=$( [[ -n "$EPOCH" ]] && date -r "$EPOCH" "+%m月%d日 %H:%M" || print "$EXP")
  print -P "\n%F{green}%B全部完成！%b%f 这次签名有效到：%B$LOCAL_EXP%b"
  print "到期后 App 会打不开，到时候电视开着、再双击本文件就能续上，收藏和历史都会保留。"
else
  print -P "\n%F{green}%B全部完成！%b%f"
fi
print "可以关闭这个窗口了。"
