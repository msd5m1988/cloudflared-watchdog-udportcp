#!/bin/sh
# cloudflared 自动切换：QUIC(UDP) 优先，不通换 http2(TCP)，每小时试回一次 QUIC
# 用法：把 TEST_URL 改成你本站的隧道域名（公司 hmad 用 https://opad.159966.xyz ，家里 Kwrt 用 https://opht.159968.xyz）
# 放到路由器 /root/cloudflared-watchdog.sh ，chmod +x ，再加 cron
# 每 5 分钟跑一次：*/5 * * * * /root/cloudflared-watchdog.sh check
# 每小时试一次 QUIC（运营商是时断时通，不是全天封）：0 * * * * /root/cloudflared-watchdog.sh try-quic
TEST_URL="https://opad.159966.xyz"
LOG="/tmp/cloudflared-watchdog.log"
MODE="$1"

get_proto() { uci get cloudflared.config.protocol 2>/dev/null || echo "auto"; }
set_proto() {
  uci set cloudflared.config.protocol="$1"
  uci commit cloudflared
  /etc/init.d/cloudflared restart
  echo "$(date '+%Y-%m-%d %H:%M:%S') 切换到 $1" >> "$LOG"
}
# 隧道通不通：curl 能拿到 200/301/302/400 都算通（400 是 HA 的正常返回），000/502/503/1033 算不通
tunnel_ok() {
  code=$(curl -sk -o /dev/null -w "%{http_code}" -m 15 "$TEST_URL" 2>/dev/null)
  case "$code" in 200|301|302|303|400|401|403) return 0 ;; *) return 1 ;; esac
}

if [ "$MODE" = "check" ]; then
  # 连着 3 次都查不到，才算真断了，避免一次抖动就切换
  if tunnel_ok; then exit 0; fi
  sleep 20; if tunnel_ok; then exit 0; fi
  sleep 20; if tunnel_ok; then exit 0; fi
  proto=$(get_proto)
  if [ "$proto" != "http2" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') 隧道不通，$proto -> http2" >> "$LOG"
    set_proto http2
  fi
  exit 0
fi

if [ "$MODE" = "try-quic" ]; then
  proto=$(get_proto)
  if [ "$proto" = "quic" ] || [ "$proto" = "auto" ]; then exit 0; fi
  # 现在是 http2，每小时试一次 QUIC（时断时通，每天一次不够）
  set_proto quic
  sleep 120
  if tunnel_ok; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用成功，保持 quic" >> "$LOG"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用失败，换回 http2" >> "$LOG"
    set_proto http2
  fi
  exit 0
fi

echo "用法: $0 check | try-quic"
