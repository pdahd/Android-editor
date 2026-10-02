#!/bin/bash
# vmargo.sh —— VMess-WS + Cloudflare 固定隧道（精简版）
# 安装：
#   vmpt="54321" uuid="xxxx" argo="vmpt" agn="proxy.example.com" agk="eyJ..." \
#   bash <(curl -Ls https://raw.githubusercontent.com/<你的用户名>/<仓库>/main/vmargo.sh) 2>&1 | tee output.log
# 管理：
#   bash <(curl -Ls .../vmargo.sh) list   # 查看 443 节点
#   bash <(curl -Ls .../vmargo.sh) res    # 重启
#   bash <(curl -Ls .../vmargo.sh) log    # 看最近日志
#   bash <(curl -Ls .../vmargo.sh) del    # 卸载
set -Eeuo pipefail
export LANG=en_US.UTF-8

BASE=/opt/vmargo
XR_SVC=vmargo-xray
CF_SVC=vmargo-tunnel
CMD="${1:-install}"

die(){ printf '错误：%s\n' "$*" >&2; exit 1; }
need_root(){ (( EUID == 0 )) || die "请以 root 运行"; }

show(){
  [[ -s $BASE/vmess.txt ]] || die "未安装"
  echo "========================================"
  printf '%-14s: %s\n' "$XR_SVC" "$(systemctl is-active $XR_SVC 2>/dev/null || true)"
  printf '%-14s: %s\n' "$CF_SVC" "$(systemctl is-active $CF_SVC 2>/dev/null || true)"
  [[ -s $BASE/info.txt ]] && cat "$BASE/info.txt"
  echo "----------------------------------------"
  echo "v2rayNG 443 节点："
  echo
  cat "$BASE/vmess.txt"
  echo "========================================"
}

do_del(){
  need_root
  systemctl disable --now $XR_SVC $CF_SVC >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/$XR_SVC.service /etc/systemd/system/$CF_SVC.service
  systemctl daemon-reload
  rm -rf "$BASE"
  echo "已卸载"
}

do_res(){
  need_root
  systemctl restart $XR_SVC $CF_SVC
  sleep 2
  show
}

do_log(){ journalctl -u $XR_SVC -u $CF_SVC -n 60 --no-pager; }

do_install(){
  need_root
  [[ -d /run/systemd/system ]] || die "此精简版需要 systemd"
  for c in curl base64 systemctl; do command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"; done

  # ---- 变量：首次必填；之后未传入的自动沿用上次保存值 ----
  vmpt="${vmpt:-}"; uuid="${uuid:-}"; agn="${agn:-}"; agk="${agk:-}"
  cfip="${cfip:-}"; name="${name:-}"
  if [[ -s $BASE/env ]]; then
    # shellcheck disable=SC1091
    . "$BASE/env"
    vmpt="${vmpt:-${saved_vmpt:-}}"; uuid="${uuid:-${saved_uuid:-}}"
    agn="${agn:-${saved_agn:-}}";   agk="${agk:-${saved_agk:-}}"
    cfip="${cfip:-${saved_cfip:-}}"; name="${name:-${saved_name:-}}"
  fi
  cfip="${cfip:-www.shopify.com}"

  [[ $vmpt =~ ^[0-9]{1,5}$ ]] && (( vmpt >= 1 && vmpt <= 65535 )) || die "vmpt 需为 1-65535 的端口（当前：'$vmpt'）"
  [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || die "uuid 格式不正确"
  [[ $agn =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || die "agn 域名格式不正确"
  [[ -n $agk ]] || die "agk（Tunnel Token）不能为空"
  [[ $cfip =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || die "cfip 格式不正确"

  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "仅支持 amd64 / arm64" ;;
  esac

  umask 077
  mkdir -p "$BASE"

  if [[ ! -x $BASE/xray ]]; then
    echo "下载 Xray ($arch) ..."
    curl -fL --retry 3 -o "$BASE/xray.tmp" \
      "https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$arch"
    chmod 755 "$BASE/xray.tmp" && mv "$BASE/xray.tmp" "$BASE/xray"
  fi
  if [[ ! -x $BASE/cloudflared ]]; then
    echo "下载 cloudflared ($arch) ..."
    curl -fL --retry 3 -o "$BASE/cloudflared.tmp" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
    chmod 755 "$BASE/cloudflared.tmp" && mv "$BASE/cloudflared.tmp" "$BASE/cloudflared"
  fi
  "$BASE/xray" version >/dev/null || die "xray 无法运行"
  "$BASE/cloudflared" version >/dev/null || die "cloudflared 无法运行"
  echo "Xray: $("$BASE/xray" version | awk '/^Xray/{print $2}')"
  echo "cloudflared: $("$BASE/cloudflared" version | awk '{print $3}')"

  printf '%s' "$agk" > "$BASE/tunnel.token"
  cat > "$BASE/env" <<EOF
saved_vmpt='$vmpt'
saved_uuid='$uuid'
saved_agn='$agn'
saved_agk='$agk'
saved_cfip='$cfip'
saved_name='$name'
EOF

  cat > "$BASE/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": $vmpt,
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$uuid", "alterId": 0 } ] },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "/$uuid-vm" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
  "$BASE/xray" run -test -c "$BASE/config.json" >/dev/null || die "xray 配置校验失败"

  cat > /etc/systemd/system/$XR_SVC.service <<EOF
[Unit]
Description=VMess WebSocket origin (vmargo)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BASE/xray run -c $BASE/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/$CF_SVC.service <<EOF
[Unit]
Description=Cloudflare Tunnel (vmargo)
After=network-online.target $XR_SVC.service
Wants=network-online.target
Requires=$XR_SVC.service

[Service]
Type=simple
ExecStart=$BASE/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token-file $BASE/tunnel.token
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # 同机装过原版 argosbx 时，停掉旧服务避免端口/隧道重复
  for old in xr argo; do
    if [[ -f /etc/systemd/system/$old.service ]] && grep -q '/agsbx/' /etc/systemd/system/$old.service; then
      echo "检测到旧版 argosbx 服务 $old，已停用"
      systemctl disable --now $old >/dev/null 2>&1 || true
    fi
  done

  systemctl daemon-reload
  systemctl enable $XR_SVC $CF_SVC >/dev/null
  systemctl restart $XR_SVC
  systemctl restart $CF_SVC
  sleep 3
  for s in $XR_SVC $CF_SVC; do
    systemctl is-active --quiet $s || { systemctl status $s --no-pager -l || true; die "$s 未正常运行"; }
  done

  ps_name="${name:+$name-}vmess-ws-tls-argo-$(uname -n)-443"
  printf -v client '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s-vm","tls":"tls","sni":"%s","alpn":"","fp":"chrome"}' \
    "$ps_name" "$cfip" "$uuid" "$agn" "$uuid" "$agn"
  link="vmess://$(printf '%s' "$client" | base64 | tr -d '\n')"
  printf '%s\n' "$link" > "$BASE/vmess.txt"
  cat > "$BASE/info.txt" <<EOF
本地监听  : 127.0.0.1:$vmpt
UUID      : $uuid
Argo 域名 : $agn
WS 路径   : /$uuid-vm
客户端地址: $cfip:443  (可自行换优选 IP/域名)
EOF
  echo "安装完成"
  show
}

case "$CMD" in
  install)       do_install ;;
  list|info)     show ;;
  res|restart)   do_res ;;
  log)           do_log ;;
  del|uninstall) do_del ;;
  *) die "未知命令：$CMD（可用：list / res / log / del）" ;;
esac
