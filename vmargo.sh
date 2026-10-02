#!/usr/bin/env bash
# vmargo.sh —— VMess-WS + Cloudflare 固定隧道（精简版）
# 安装：
#   vmpt="54321" uuid="xxx" argo="vmpt" agn="proxy.example.com" agk="eyJ..." \
#   bash vmargo.sh
# 管理： bash vmargo.sh list | res | log | up | del
set -Eeuo pipefail
export LANG=C.UTF-8

BASE="${VMARGO_DIR:-/opt/vmargo}"
XR_SVC=vmargo-xray
CF_SVC=vmargo-tunnel
UNIT_DIR=/etc/systemd/system
XR_UNIT="$UNIT_DIR/$XR_SVC.service"
CF_UNIT="$UNIT_DIR/$CF_SVC.service"
CMD="${1:-install}"

die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[提示] %s\n' "$*" >&2; }

# ---------- 环境探测：systemd 真正可用才走 systemd ----------
HAVE_SYSTEMD=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 \
   && systemctl show-environment >/dev/null 2>&1; then
  HAVE_SYSTEMD=1
fi

need_root(){ [ "$(id -u)" = 0 ] || die "请以 root 运行"; }

read_saved(){ [ -r "$BASE/$1" ] && cat -- "$BASE/$1" || true; }
save_val(){ printf '%s\n' "$2" > "$BASE/$1"; chmod 600 "$BASE/$1"; }

arch_of(){
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "仅支持 amd64 / arm64，当前：$(uname -m)" ;;
  esac
}

fetch(){  # fetch <url> <dest>
  local tmp="$2.tmp.$$"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$tmp" "$1" || { rm -f "$tmp"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 -O "$tmp" "$1" || { rm -f "$tmp"; return 1; }
  else
    die "需要 curl 或 wget"
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp"; mv -f "$tmp" "$2"
}

fetch_cores(){   # fetch_cores [force]
  local force="${1:-0}" a xu cu
  a=$(arch_of)
  xu="${xrayurl:-https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$a}"
  cu="${cfdurl:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a}"
  if [ ! -x "$BASE/xray" ] || [ "$force" = 1 ]; then
    info "下载 Xray ($a)"; fetch "$xu" "$BASE/xray" || die "Xray 下载失败"
  fi
  if [ ! -x "$BASE/cloudflared" ] || [ "$force" = 1 ]; then
    info "下载 cloudflared ($a)"; fetch "$cu" "$BASE/cloudflared" || die "cloudflared 下载失败"
  fi
  "$BASE/xray" version >/dev/null 2>&1 || die "Xray 无法执行（架构不符或文件损坏）"
  "$BASE/cloudflared" version >/dev/null 2>&1 || die "cloudflared 无法执行"
  info "Xray: $("$BASE/xray" version 2>/dev/null | head -n1)"
  info "cloudflared: $("$BASE/cloudflared" version 2>/dev/null | head -n1)"
}

# ---------- 无 systemd 时的进程管理 ----------
pid_alive(){  # pid_alive <pidfile> <关键字>
  local f="$1" k="$2" p c
  [ -r "$f" ] || return 1
  p=$(cat "$f" 2>/dev/null || true)
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  [ -r "/proc/$p/cmdline" ] || return 0
  c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)
  case "$c" in *"$k"*) return 0 ;; *) return 1 ;; esac
}

kill_bg(){  # kill_bg <pidfile> <关键字>
  local f="$1" k="$2" p i=0
  if pid_alive "$f" "$k"; then
    p=$(cat "$f"); kill -TERM "$p" 2>/dev/null || true
    while [ $i -lt 10 ] && pid_alive "$f" "$k"; do sleep 1; i=$((i+1)); done
    pid_alive "$f" "$k" && kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$f"
}

is_up(){
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl is-active --quiet "$1.service"
    return $?
  fi
  case "$1" in
    "$XR_SVC") pid_alive "$BASE/xray.pid" "$BASE/xray" ;;
    "$CF_SVC") pid_alive "$BASE/cloudflared.pid" "$BASE/cloudflared" ;;
    *) return 1 ;;
  esac
}
stat_of(){ if is_up "$1"; then printf '运行中'; else printf '未运行'; fi; }

# cloudflared 参数：优先 --token-file，旧版回退 --token
tok_args(){
  if "$BASE/cloudflared" tunnel run --help 2>&1 | grep -q -- '--token-file'; then
    printf -- '--token-file %s' "$BASE/tunnel.token"
  else
    printf -- '--token %s' "$(cat "$BASE/tunnel.token")"
  fi
}

start_bg(){
  command -v nohup >/dev/null 2>&1 || die "缺少 nohup"
  kill_bg "$BASE/cloudflared.pid" "$BASE/cloudflared"
  kill_bg "$BASE/xray.pid" "$BASE/xray"
  : > "$BASE/xray.log"; : > "$BASE/cloudflared.log"

  nohup "$BASE/xray" run -c "$BASE/config.json" >>"$BASE/xray.log" 2>&1 </dev/null &
  echo $! > "$BASE/xray.pid"
  sleep 1
  pid_alive "$BASE/xray.pid" "$BASE/xray" || { tail -n 30 "$BASE/xray.log" || true; return 1; }

  # shellcheck disable=SC2046
  nohup "$BASE/cloudflared" tunnel --no-autoupdate --edge-ip-version auto \
      --protocol http2 run $(tok_args) >>"$BASE/cloudflared.log" 2>&1 </dev/null &
  echo $! > "$BASE/cloudflared.pid"
  sleep 1
  pid_alive "$BASE/cloudflared.pid" "$BASE/cloudflared" || { tail -n 30 "$BASE/cloudflared.log" || true; return 1; }
}

wait_tunnel(){
  local i=0 logs
  while [ $i -lt 30 ]; do
    if [ "$HAVE_SYSTEMD" = 1 ] && command -v journalctl >/dev/null 2>&1; then
      logs=$(journalctl -u "$CF_SVC.service" -n 200 --no-pager 2>/dev/null || true)
    else
      logs=$(tail -n 200 "$BASE/cloudflared.log" 2>/dev/null || true)
    fi
    case "$logs" in *"Registered tunnel connection"*) info "隧道已注册连接"; return 0 ;; esac
    is_up "$CF_SVC" || { warn "cloudflared 已退出，用 log 命令查看"; return 0; }
    sleep 1; i=$((i+1))
  done
  warn "30 秒内未确认隧道连接，可执行 log 子命令查看"
}

start_all(){
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl daemon-reload
    systemctl enable "$XR_SVC.service" "$CF_SVC.service" >/dev/null 2>&1 || true
    systemctl restart "$XR_SVC.service" || { systemctl status "$XR_SVC.service" --no-pager -l || true; die "Xray 启动失败"; }
    systemctl restart "$CF_SVC.service" || { systemctl status "$CF_SVC.service" --no-pager -l || true; die "cloudflared 启动失败"; }
  else
    start_bg || die "后台进程启动失败（见上方日志）"
  fi
  sleep 2
  is_up "$XR_SVC" || { [ "$HAVE_SYSTEMD" = 1 ] && systemctl status "$XR_SVC.service" --no-pager -l || tail -n 30 "$BASE/xray.log"; die "Xray 未运行"; }
  is_up "$CF_SVC" || { [ "$HAVE_SYSTEMD" = 1 ] && systemctl status "$CF_SVC.service" --no-pager -l || tail -n 30 "$BASE/cloudflared.log"; die "cloudflared 未运行"; }
  wait_tunnel
}

mk_link(){  # add uuid agn 前缀
  local node payload
  node=$(uname -n | tr -cd 'A-Za-z0-9._-'); [ -n "$node" ] || node=host
  payload=$(printf '{"v":"2","ps":"%svmess-ws-tls-argo-%s-443","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":"tls","sni":"%s","alpn":"","fp":"chrome"}' \
    "$4" "$node" "$1" "$2" "$3" "$2" "$3")
  printf 'vmess://%s' "$(printf '%s' "$payload" | base64 | tr -d '\r\n')"
}

do_show(){
  need_root
  [ -s "$BASE/vmess.txt" ] || die "未安装，请先带参数运行安装命令"
  echo "========================================"
  printf '%-16s: %s\n' "$XR_SVC" "$(stat_of "$XR_SVC")"
  printf '%-16s: %s\n' "$CF_SVC" "$(stat_of "$CF_SVC")"
  [ "$HAVE_SYSTEMD" = 1 ] && echo "运行方式          : systemd（开机自启）" \
                          || echo "运行方式          : nohup 临时进程（重启后消失）"
  [ -r "$BASE/info.txt" ] && cat "$BASE/info.txt"
  echo "----------------------------------------"
  echo "v2rayNG 443 节点："
  cat "$BASE/vmess.txt"
  echo "========================================"
}

do_log(){
  need_root
  if [ "$HAVE_SYSTEMD" = 1 ] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$XR_SVC.service" -u "$CF_SVC.service" -n 80 --no-pager
  else
    echo "--- xray.log ---";        tail -n 40 "$BASE/xray.log" 2>/dev/null || true
    echo "--- cloudflared.log ---"; tail -n 60 "$BASE/cloudflared.log" 2>/dev/null || true
  fi
}

do_del(){
  need_root
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl disable --now "$CF_SVC.service" "$XR_SVC.service" >/dev/null 2>&1 || true
    rm -f "$XR_UNIT" "$CF_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    kill_bg "$BASE/cloudflared.pid" "$BASE/cloudflared"
    kill_bg "$BASE/xray.pid" "$BASE/xray"
  fi
  rm -rf "$BASE"
  info "已卸载并删除 $BASE"
}

do_install(){
  need_root
  command -v base64 >/dev/null 2>&1 || die "缺少 base64"
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "需要 curl 或 wget"

  umask 077; mkdir -p "$BASE"; chmod 700 "$BASE"

  local p u d k a n pn
  p="${vmpt:-$(read_saved port)}"
  u="${uuid:-$(read_saved uuid)}"
  d="${agn:-$(read_saved agn)}"
  k="${agk:-$(read_saved tunnel.token)}"
  a="${cfip:-$(read_saved cfip)}"
  n="${name:-$(read_saved name)}"

  [ -z "${argo:-}" ] || [ "$argo" = vmpt ] || die '此精简版只支持 argo="vmpt"'

  if [ -z "$p" ]; then
    p=$(awk 'BEGIN{srand();printf "%d",10000+int(rand()*55000)}'); info "未指定端口，随机使用 $p"
  fi
  case "$p" in ''|*[!0-9]*) die "vmpt 必须为数字端口" ;; esac
  pn=$((10#$p)); [ "$pn" -ge 1 ] && [ "$pn" -le 65535 ] || die "vmpt 需在 1-65535"; p=$pn

  [ -n "$d" ] || die "缺少 agn（隧道绑定域名）"
  echo "$d" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$' \
    || die "agn 域名格式不正确"
  [ -n "$k" ] || die "缺少 agk（Tunnel Token）"
  case "$k" in *[[:space:]]*) die "agk 含空白字符，请确认完整复制" ;; esac
  echo "$k" | grep -qE '省略|你的|填' && die "agk 仍是占位文字"

  a="${a:-www.shopify.com}"
  n="${n:-}"

  # 清理旧进程 / 旧 argosbx 服务
  if [ "$HAVE_SYSTEMD" = 1 ]; then
    for s in xr argo; do
      if [ -f "$UNIT_DIR/$s.service" ] && grep -q '/agsbx/' "$UNIT_DIR/$s.service"; then
        info "停用旧版 argosbx 服务：$s"
        systemctl disable --now "$s" >/dev/null 2>&1 || true
      fi
    done
    systemctl stop "$CF_SVC.service" "$XR_SVC.service" >/dev/null 2>&1 || true
  else
    kill_bg "$BASE/cloudflared.pid" "$BASE/cloudflared"
    kill_bg "$BASE/xray.pid" "$BASE/xray"
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$" \
      && warn "端口 $p 已有监听，若非本脚本残留请更换 vmpt"
  fi

  fetch_cores

  if [ -z "$u" ]; then u=$("$BASE/xray" uuid); info "已生成新 UUID：$u"; fi
  echo "$u" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
    || die "uuid 格式不正确"

  save_val port "$p"; save_val uuid "$u"; save_val agn "$d"
  save_val cfip "$a"; save_val name "$n"
  printf '%s' "$k" > "$BASE/tunnel.token"; chmod 600 "$BASE/tunnel.token"

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
  "$BASE/xray" run -test -c "$BASE/config.json" >/dev/null || die "Xray 配置校验失败"

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    cat > "$XR_UNIT" <<EOF
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
    cat > "$CF_UNIT" <<EOF
[Unit]
Description=vmargo Cloudflare Tunnel
After=network-online.target $XR_SVC.service
Wants=network-online.target
Requires=$XR_SVC.service

[Service]
Type=simple
WorkingDirectory=$BASE
ExecStart=$BASE/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run $(tok_args)
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$XR_UNIT"; chmod 600 "$CF_UNIT"
  fi

  start_all

  local pre link
  pre=""; [ -n "$n" ] && pre="$n-"
  link=$(mk_link "$a" "$u" "$d" "$pre")
  printf '%s\n' "$link" > "$BASE/vmess.txt"; chmod 600 "$BASE/vmess.txt"
  cat > "$BASE/info.txt" <<EOF
本地监听          : 127.0.0.1:$p
UUID              : $u
Argo 域名         : $d
WS 路径           : /$u-vm
客户端地址        : $a:443（可换优选 IP/域名）
EOF
  chmod 600 "$BASE/info.txt"

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    info "已用 systemd 托管，开机自启"
  else
    info "当前无 systemd，已用 nohup 临时运行（Colab 运行时结束即消失）"
  fi
  info "请确认 Cloudflare 该域名的 Service 指向 http://localhost:$p"
  do_show
}

case "$CMD" in
  install|"")    do_install ;;
  list|info)     do_show ;;
  res|restart)   need_root; [ -s "$BASE/config.json" ] || die "未安装"; start_all; do_show ;;
  log)           do_log ;;
  up)            need_root; [ -s "$BASE/config.json" ] || die "未安装"; fetch_cores 1; start_all; do_show ;;
  del|uninstall) do_del ;;
  *) die "未知命令：$CMD（可用 list / res / log / up / del）" ;;
esac
