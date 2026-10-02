#!/usr/bin/env bash
# vmargo.sh —— VMess-WS + Cloudflare 固定隧道（精简版，兼容 systemd VPS 与 Google Colab）
#
# 安装（命令不变）：
#   vmpt="54321" uuid="xxxx" argo="vmpt" agn="proxy.example.com" agk="eyJ..." \
#   bash <(curl -Ls https://raw.githubusercontent.com/<用户>/<仓库>/main/vmargo.sh)
#
# 管理（安装后无需再带变量）：
#   bash <(curl -Ls <脚本地址>) list | res | log | up | del
#
# 可选变量：cfip（客户端连接地址，默认 www.shopify.com） name（节点名前缀）
#           xrayurl / cfdurl（自定义内核下载地址）

set -u
set -o pipefail
export LANG=C.UTF-8

XR_SVC=vmargo-xray
CF_SVC=vmargo-tunnel
UNIT_DIR=/etc/systemd/system
CMD="${1:-install}"

if [ -n "${VMARGO_DIR:-}" ]; then
  BASE="$VMARGO_DIR"
elif [ "$(id -u)" = 0 ]; then
  BASE=/opt/vmargo
else
  BASE="${HOME:-/tmp}/.vmargo"
fi

die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[提示] %s\n' "$*" >&2; }

# ---------------- 环境探测：仅当 systemd 真正可用才使用 ----------------
HAVE_SYSTEMD=0
if [ "$(id -u)" = 0 ] && [ -d /run/systemd/system ] \
   && command -v systemctl >/dev/null 2>&1 \
   && systemctl list-unit-files >/dev/null 2>&1; then
  HAVE_SYSTEMD=1
fi

# ---------------- 参数保存与读取 ----------------
read_saved() { if [ -r "$BASE/$1" ]; then cat -- "$BASE/$1"; fi; }
save_val()   { printf '%s\n' "$2" > "$BASE/$1"; chmod 600 "$BASE/$1"; }

# ---------------- 下载 ----------------
get_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "仅支持 amd64 / arm64，当前架构：$(uname -m)" ;;
  esac
}

fetch() { # fetch <url> <dest>
  local url="$1" dest="$2" tmp="$2.part"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$tmp" "$url" \
      || { rm -f "$tmp"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 -O "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  else
    return 1
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp" && mv -f "$tmp" "$dest"
}

ensure_core() { # ensure_core <名称> <url> <force:0|1>
  local bin="$BASE/$1"
  if [ "$3" != 1 ] && [ -x "$bin" ] && "$bin" version >/dev/null 2>&1; then
    return 0
  fi
  info "下载 $1 ……"
  fetch "$2" "$bin" || die "$1 下载失败（请检查网络或 GitHub 访问）"
  "$bin" version >/dev/null 2>&1 || die "$1 无法运行（文件损坏或架构不符）"
}

fetch_cores() { # fetch_cores [force]
  local force="${1:-0}" arch
  arch="$(get_arch)"
  ensure_core xray "${xrayurl:-https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$arch}" "$force"
  ensure_core cloudflared "${cfdurl:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch}" "$force"
  info "Xray：$("$BASE/xray" version 2>/dev/null | head -n 1)"
  info "Cloudflared：$("$BASE/cloudflared" version 2>/dev/null | head -n 1)"
}

# ---------------- 进程管理（无 systemd 时使用，不依赖 pid 文件）----------------
pids_of() { # 列出可执行文件路径完全匹配的进程 PID
  local bin="$1" d p first
  for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    [ -r "$d/cmdline" ] || continue
    first=""
    IFS= read -r -d '' first < "$d/cmdline" || true
    [ "$first" = "$bin" ] && printf '%s\n' "$p"
  done
  return 0
}

stop_bin() {
  local bin="$1" list i
  list="$(pids_of "$bin")"
  [ -n "$list" ] || return 0
  # shellcheck disable=SC2086
  kill -TERM $list 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(pids_of "$bin")" ] && return 0
    sleep 1
  done
  list="$(pids_of "$bin")"
  # shellcheck disable=SC2086
  [ -z "$list" ] || kill -KILL $list 2>/dev/null || true
  return 0
}

detach() { # detach <日志文件> <命令...>：完全脱离当前管道，避免卡住 tee
  local log="$1"; shift
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$@" >>"$log" 2>&1 </dev/null &
  else
    nohup "$@" >>"$log" 2>&1 </dev/null &
  fi
  return 0
}

is_up() { # is_up xray|tunnel
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    case "$1" in
      xray)   systemctl is-active --quiet "$XR_SVC.service" ;;
      tunnel) systemctl is-active --quiet "$CF_SVC.service" ;;
    esac
    return $?
  fi
  case "$1" in
    xray)   [ -n "$(pids_of "$BASE/xray")" ] ;;
    tunnel) [ -n "$(pids_of "$BASE/cloudflared")" ] ;;
  esac
}

stat_of() { if is_up "$1"; then printf '运行中'; else printf '未运行'; fi; }

stop_all() {
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl stop "$CF_SVC.service" "$XR_SVC.service" >/dev/null 2>&1 || true
  fi
  stop_bin "$BASE/cloudflared"
  stop_bin "$BASE/xray"
}

port_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

show_failure_logs() {
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl status "$XR_SVC.service" --no-pager -l 2>&1 | tail -n 15 || true
    systemctl status "$CF_SVC.service" --no-pager -l 2>&1 | tail -n 15 || true
  else
    echo '--- xray.log ---';        tail -n 30 "$BASE/xray.log" 2>/dev/null || true
    echo '--- cloudflared.log ---'; tail -n 30 "$BASE/cloudflared.log" 2>/dev/null || true
  fi
}

start_all() {
  local port
  port="$(read_saved port)"

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl daemon-reload
    systemctl enable "$XR_SVC.service" "$CF_SVC.service" >/dev/null 2>&1 || true
    systemctl restart "$XR_SVC.service" || { show_failure_logs; die 'Xray 服务启动失败'; }
    systemctl restart "$CF_SVC.service" || { show_failure_logs; die 'Cloudflared 服务启动失败'; }
  else
    command -v nohup >/dev/null 2>&1 || die '当前环境缺少 nohup'
    stop_bin "$BASE/cloudflared"
    stop_bin "$BASE/xray"
    : > "$BASE/xray.log"
    : > "$BASE/cloudflared.log"
    detach "$BASE/xray.log" "$BASE/xray" run -c "$BASE/config.json"
    sleep 2
    is_up xray || { show_failure_logs; die 'Xray 启动失败'; }
    (
      export TUNNEL_TOKEN
      TUNNEL_TOKEN="$(cat "$BASE/tunnel.token")"
      detach "$BASE/cloudflared.log" "$BASE/cloudflared" tunnel \
        --no-autoupdate --edge-ip-version auto --protocol http2 run
    )
    sleep 2
    is_up tunnel || { show_failure_logs; die 'Cloudflared 启动失败'; }
  fi

  sleep 1
  is_up xray   || { show_failure_logs; die 'Xray 未在运行'; }
  is_up tunnel || { show_failure_logs; die 'Cloudflared 未在运行'; }

  if port_listening "$port"; then
    info "Xray 已在本机 127.0.0.1:$port 监听"
  else
    warn "未检测到本机端口 $port 在监听，请执行 log 子命令查看日志"
  fi
}

# ---------------- 隧道与链路检查 ----------------
wait_tunnel() { # wait_tunnel <起始时间>
  local since="$1" i logs
  for i in $(seq 1 40); do
    if [ "$HAVE_SYSTEMD" = 1 ] && command -v journalctl >/dev/null 2>&1; then
      logs="$(journalctl -u "$CF_SVC.service" --since "$since" --no-pager -n 300 2>/dev/null || true)"
    else
      logs="$(tail -n 300 "$BASE/cloudflared.log" 2>/dev/null || true)"
    fi
    case "$logs" in
      *"Registered tunnel connection"*) info 'Cloudflare 隧道已注册连接'; return 0 ;;
    esac
    is_up tunnel || { warn 'Cloudflared 已退出，请执行 log 子命令查看原因（常见：Token 错误）'; return 0; }
    sleep 1
  done
  warn '40 秒内没有确认隧道连接，请执行 log 子命令查看'
  return 0
}

e2e_check() { # e2e_check <域名> <uuid>
  command -v curl >/dev/null 2>&1 || return 0
  local code i
  for i in 1 2 3; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$1/$2-vm" 2>/dev/null || true)"
    case "$code" in
      ''|000|5*) sleep 3 ;;
      *) info "端到端检查通过：https://$1 返回 HTTP $code"; return 0 ;;
    esac
  done
  case "$code" in
    000|'') warn "无法访问 https://$1：请确认域名已在 Cloudflare 绑定到这条隧道" ;;
    *)      warn "https://$1 返回 HTTP $code：请在 Cloudflare 隧道后台把该域名的 Service 设为 http://localhost:$(read_saved port)（仍 502 则改 127.0.0.1）" ;;
  esac
  return 0
}

# ---------------- 节点链接 ----------------
mk_link() { # mk_link <地址> <uuid> <域名> <前缀>
  local node payload
  node="$(uname -n | tr -cd 'A-Za-z0-9._-')"
  [ -n "$node" ] || node=host
  payload="$(printf '{"v":"2","ps":"%svmess-ws-tls-argo-%s-443","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":"tls","sni":"%s","alpn":"","fp":"chrome"}' \
    "$4" "$node" "$1" "$2" "$3" "$2" "$3")"
  printf 'vmess://%s' "$(printf '%s' "$payload" | base64 | tr -d '\r\n')"
}

do_show() {
  local p u d a n pre
  p="$(read_saved port)"; u="$(read_saved uuid)"; d="$(read_saved agn)"
  a="$(read_saved cfip)"; n="$(read_saved name)"
  [ -n "$u" ] && [ -n "$p" ] && [ -n "$d" ] || die '没有找到安装记录，请先带参数运行安装命令'
  pre=""; [ -z "$n" ] || pre="$n-"
  echo '========================================'
  printf '%-18s: %s\n' "$XR_SVC" "$(stat_of xray)"
  printf '%-18s: %s\n' "$CF_SVC" "$(stat_of tunnel)"
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    echo '运行方式          : systemd（开机自启）'
  else
    echo '运行方式          : 后台进程（无 systemd，重启或运行时结束后消失）'
  fi
  echo "本地监听          : 127.0.0.1:$p"
  echo "UUID              : $u"
  echo "Argo 域名         : $d"
  echo "WS 路径           : /$u-vm"
  echo "客户端地址        : ${a:-www.shopify.com}:443（可自行换优选 IP/域名）"
  echo '----------------------------------------'
  echo 'v2rayNG 443 节点：'
  mk_link "${a:-www.shopify.com}" "$u" "$d" "$pre"
  echo
  echo '========================================'
}

do_log() {
  if [ "$HAVE_SYSTEMD" = 1 ] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$XR_SVC.service" -u "$CF_SVC.service" -n 80 --no-pager
  else
    echo '--- xray.log ---';        tail -n 40 "$BASE/xray.log" 2>/dev/null || true
    echo '--- cloudflared.log ---'; tail -n 60 "$BASE/cloudflared.log" 2>/dev/null || true
  fi
}

do_del() {
  stop_all
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl disable "$CF_SVC.service" "$XR_SVC.service" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$XR_SVC.service" "$UNIT_DIR/$CF_SVC.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -rf "$BASE"
  info "已停止服务并删除 $BASE"
}

# ---------------- 安装 ----------------
do_install() {
  command -v base64 >/dev/null 2>&1 || die '系统缺少 base64'
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die '系统需要 curl 或 wget'

  umask 077
  mkdir -p "$BASE" || die "无法创建目录 $BASE"
  chmod 700 "$BASE"

  local p u d k a n
  p="${vmpt:-$(read_saved port)}"
  u="${uuid:-$(read_saved uuid)}"
  d="${agn:-$(read_saved agn)}"
  k="${agk:-$(cat "$BASE/tunnel.token" 2>/dev/null || true)}"
  a="${cfip:-$(read_saved cfip)}"
  n="${name:-$(read_saved name)}"

  # 去掉复制时可能带入的空白和换行
  p="${p//[[:space:]]/}"; u="${u//[[:space:]]/}"; d="${d//[[:space:]]/}"
  k="${k//[[:space:]]/}"; a="${a//[[:space:]]/}"; n="${n//[[:space:]]/}"

  [ -z "${argo:-}" ] || [ "$argo" = vmpt ] || die '此精简版只支持 argo="vmpt"'

  if [ -z "$p" ]; then
    p=$(( (RANDOM * 32768 + RANDOM) % 55536 + 10000 ))
    info "未指定 vmpt，使用随机端口 $p"
  fi
  case "$p" in ''|*[!0-9]*) die 'vmpt 必须是数字端口' ;; esac
  p=$((10#$p))
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die 'vmpt 必须在 1-65535 之间'

  local re_dom='^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'
  [[ "$d" =~ $re_dom ]] || die 'agn 必须是完整域名，例如 proxy.example.com'

  local re_tok='^[A-Za-z0-9+/=_-]{40,}$'
  [[ "$k" =~ $re_tok ]] || die 'agk 不是有效的 Tunnel Token：请粘贴完整 Token（不能含省略号、中文或占位文字）'

  a="${a:-www.shopify.com}"
  local re_addr='^[A-Za-z0-9.-]+$' re_v6='^\[[0-9A-Fa-f:.]+\]$'
  [[ "$a" =~ $re_addr || "$a" =~ $re_v6 ]] || die 'cfip 只能是主机名、IPv4，或带方括号的 IPv6'

  local re_name='^[A-Za-z0-9._-]*$'
  [[ "$n" =~ $re_name ]] || die 'name 仅支持英文字母、数字、点、下划线、连字符'

  # 停掉本脚本旧进程，并停用同机旧版 argosbx 的服务以免冲突
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    local s
    for s in xr argo; do
      if [ -f "$UNIT_DIR/$s.service" ] && grep -q '/agsbx/' "$UNIT_DIR/$s.service"; then
        info "停用旧版 argosbx 服务：$s"
        systemctl disable --now "$s.service" >/dev/null 2>&1 || true
      fi
    done
  fi
  stop_all

  if port_listening "$p"; then
    die "本机端口 $p 已被其他程序占用，请换一个 vmpt"
  fi

  fetch_cores

  if [ -z "$u" ]; then
    u="$("$BASE/xray" uuid 2>/dev/null)"
    info "未指定 uuid，已生成：$u"
  fi
  local re_uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  [[ "$u" =~ $re_uuid ]] || die 'uuid 格式不正确（应为 8-4-4-4-12 位十六进制）'

  save_val port "$p"; save_val uuid "$u"; save_val agn "$d"
  save_val cfip "$a"; save_val name "$n"
  printf '%s' "$k" > "$BASE/tunnel.token"; chmod 600 "$BASE/tunnel.token"
  printf 'TUNNEL_TOKEN=%s\n' "$k" > "$BASE/tunnel.env"; chmod 600 "$BASE/tunnel.env"

  cat > "$BASE/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": $p,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$u", "alterId": 0 } ] },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/$u-vm" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
  chmod 600 "$BASE/config.json"

  if ! "$BASE/xray" run -test -c "$BASE/config.json" >"$BASE/test.out" 2>&1; then
    cat "$BASE/test.out" >&2
    die 'Xray 配置校验失败'
  fi

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    cat > "$UNIT_DIR/$XR_SVC.service" <<EOF
[Unit]
Description=vmargo Xray (VMess-WS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/xray run -c $BASE/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > "$UNIT_DIR/$CF_SVC.service" <<EOF
[Unit]
Description=vmargo Cloudflare Tunnel
After=network-online.target $XR_SVC.service
Wants=network-online.target $XR_SVC.service

[Service]
Type=simple
WorkingDirectory=$BASE
EnvironmentFile=$BASE/tunnel.env
ExecStart=$BASE/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT_DIR/$XR_SVC.service"
    chmod 600 "$UNIT_DIR/$CF_SVC.service"
  fi

  local since
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  start_all
  wait_tunnel "$since"
  e2e_check "$d" "$u"

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    info '已用 systemd 托管，开机自启'
  else
    info '未检测到可用 systemd，已用后台进程运行（Colab 运行时结束后会消失，仅适合临时测试）'
  fi
  info "Cloudflare 隧道后台该域名的 Service 应指向 http://localhost:$p"
  do_show
}

case "$CMD" in
  install|"")    do_install ;;
  list|info)     do_show ;;
  res|restart)   [ -s "$BASE/config.json" ] || die '尚未安装'; start_all; do_show ;;
  log)           do_log ;;
  up)            [ -s "$BASE/config.json" ] || die '尚未安装'; fetch_cores 1; start_all; do_show ;;
  del|uninstall) do_del ;;
  *) die "未知命令：$CMD（可用：list / res / log / up / del）" ;;
esac
