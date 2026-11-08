#!/bin/sh
# cloudflared 自动切换 v2（2026-11-08 整改版）
# 改了什么，为什么改：
#  v1 的毛病：
#   1) try-quic 是“先切到 quic，再等 120 秒才测”——UDP 被阻时，隧道每
#      小时至少断 2 分钟，而且整点一到就断，你看着就是“到正点就刷新，
#      只能上一分钟”。
#   2) try-quic 只测 1 次就决定留不留 quic——小请求偶尔通一次就留下了，
#      实际上 UDP 丢包严重，正常上网还是断断续续。
#   3) check（每 5 分钟）和 try-quic（整点）可能同时跑，同时重启
#      cloudflared，互相打架。
#  v2 的改法：
#   1) try-quic 不再每小时试，改成每天凌晨 3 点试一次，断也只断在半夜。
#   2) 切到 quic 后只等 20 秒就开始测，连续测 3 次，3 次都通才留 quic，
#      只要有 1 次不通就马上切回 http2——坏的时候最多断约 30 秒，不再等 120 秒。
#   3) 加了锁：check 和 try-quic 同时跑时，后来的直接退出，不打架。
#   4) try-quic 失败一次，24 小时内不再试，避免白天反复折腾。
#   5) check 不变：隧道真断了（连续 3 次不通）才切回 http2；现在协议
#      本来就是 http2，check 平时什么都不做，不会重启。
# 用法：放到路由器 /root/cloudflared-watchdog.sh ，chmod +x ，再加 cron
#   每 5 分钟检查：*/5 * * * * /root/cloudflared-watchdog.sh check
#   每天凌晨 3 点试一次 QUIC：0 3 * * * /root/cloudflared-watchdog.sh try-quic
#   （不要再加回每小时的 0 * * * * try-quic）
TEST_URL="https://opad.159966.xyz"
LOG="/tmp/cloudflared-watchdog.log"
FAIL_FLAG="/tmp/cloudflared-watchdog-quic-fail"
MODE="$1"

# 锁：防止 check 和 try-quic 同时重启 cloudflared。
# 有 flock 才锁，锁不上说明另一个正在跑，直接退出；没有 flock 的固件就跳过。
if command -v flock >/dev/null 2>&1; then
  exec 9>/tmp/cloudflared-watchdog.lock
  flock -n 9 || exit 0
fi

get_proto() { uci get cloudflared.config.protocol 2>/dev/null || echo "auto"; }
set_proto() {
  uci set cloudflared.config.protocol="$1"
  uci commit cloudflared
  /etc/init.d/cloudflared restart
  echo "$(date '+%Y-%m-%d %H:%M:%S') 切换到 $1" >> "$LOG"
}
# 隧道通不通：curl 能拿到 200/301/302/400 都算通，000/502/503/1033 算不通
tunnel_ok() {
  code=$(curl -sk -o /dev/null -w "%{http_code}" -m 10 "$TEST_URL" 2>/dev/null)
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
  # 24 小时内失败过就不再试，避免白天反复断
  if [ -f "$FAIL_FLAG" ]; then
    fail_time=$(cat "$FAIL_FLAG" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$fail_time" ] && [ $((now - fail_time)) -lt 86400 ]; then
      exit 0
    fi
  fi
  # 现在是 http2，每天凌晨试一次 QUIC。先切，20 秒后连续测 3 次，
  # 3 次都通才留，不通马上切回，不再等 120 秒。
  set_proto quic
  sleep 20
  if tunnel_ok; then sleep 10; else
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用失败（第1次不通），换回 http2" >> "$LOG"
    date +%s > "$FAIL_FLAG"
    set_proto http2
    exit 0
  fi
  if tunnel_ok; then sleep 10; else
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用失败（第2次不通），换回 http2" >> "$LOG"
    date +%s > "$FAIL_FLAG"
    set_proto http2
    exit 0
  fi
  if tunnel_ok; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用成功（连续3次都通），保持 quic" >> "$LOG"
    rm -f "$FAIL_FLAG"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用失败（第3次不通），换回 http2" >> "$LOG"
    date +%s > "$FAIL_FLAG"
    set_proto http2
  fi
  exit 0
fi

echo "用法: $0 check | try-quic"
