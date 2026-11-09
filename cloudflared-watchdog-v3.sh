#!/bin/sh
# cloudflared 自动切换 v3（2026-11-09 整改版）
# v3 改了什么，为什么改：
#  v2 的毛病（用户 2026-11-09 指出）：
#   check 只会 quic -> http2 单向切。协议是 http2 时隧道断了，
#   check 什么都不做，就一直断着等到凌晨 3 点 try-quic 才动。
#   昨天 11-08 下午 17:48 就是这样：协议已经是 http2，隧道 1033
#   断了，check 却没试另一个协议。
#  v3 的改法：
#   check 现在双向试：当前协议连续 3 次不通，就切到另一个协议试。
#   quic 不通 -> 试 http2；http2 不通 -> 试 quic。
#   试另一个协议时：等 20 秒，连续测 3 次，3 次都通才留，
#   有 1 次不通就马上切回原来的协议。
#   两个协议都不通时，留在 http2（最稳的默认），不再来回切。
#   check 里试 quic 失败一次，1 小时内不再试，避免每 5 分钟
#   反复切；凌晨 3 点 try-quic 失败一次，24 小时内不再试（不变）。
#   其他 v2 的改法不变：try-quic 每天凌晨 3 点一次，20 秒后测 3 次，
#   加锁防 check 和 try-quic 同时跑。
# 用法：放到路由器 /root/cloudflared-watchdog.sh ，chmod +x ，再加 cron
#   每 5 分钟检查：*/5 * * * * /root/cloudflared-watchdog.sh check
#   每天凌晨 3 点试一次 QUIC：0 3 * * * /root/cloudflared-watchdog.sh try-quic
#   （不要再加回每小时的 0 * * * * try-quic）
TEST_URL="https://opad.159966.xyz"
LOG="/tmp/cloudflared-watchdog.log"
FAIL_FLAG="/tmp/cloudflared-watchdog-quic-fail"
CHECK_FAIL_FLAG="/tmp/cloudflared-watchdog-check-quic-fail"
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
# 连续测 3 次，3 次都通才算通
test_three_times() {
  if tunnel_ok; then sleep 10; else return 1; fi
  if tunnel_ok; then sleep 10; else return 1; fi
  if tunnel_ok; then return 0; else return 1; fi
}

if [ "$MODE" = "check" ]; then
  # 连着 3 次都查不到，才算真断了，避免一次抖动就切换
  if tunnel_ok; then exit 0; fi
  sleep 20; if tunnel_ok; then exit 0; fi
  sleep 20; if tunnel_ok; then exit 0; fi
  proto=$(get_proto)
  if [ "$proto" = "http2" ]; then
    # http2 不通，试另一个协议 quic。1 小时内试失败过就不再试。
    if [ -f "$CHECK_FAIL_FLAG" ]; then
      fail_time=$(cat "$CHECK_FAIL_FLAG" 2>/dev/null)
      now=$(date +%s)
      if [ -n "$fail_time" ] && [ $((now - fail_time)) -lt 3600 ]; then
        exit 0
      fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') 隧道不通，http2 -> 试 quic" >> "$LOG"
    set_proto quic
    sleep 20
    if test_three_times; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') http2 不通，quic 试用成功（连续3次都通），保持 quic" >> "$LOG"
      rm -f "$CHECK_FAIL_FLAG"
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') http2 不通，quic 也试不通，换回 http2" >> "$LOG"
      date +%s > "$CHECK_FAIL_FLAG"
      set_proto http2
    fi
    exit 0
  fi
  # quic（或其他协议）不通，试 http2
  echo "$(date '+%Y-%m-%d %H:%M:%S') 隧道不通，$proto -> http2" >> "$LOG"
  set_proto http2
  sleep 20
  if tunnel_ok; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') http2 试用成功，保持 http2" >> "$LOG"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') http2 也试不通，留在 http2，等下次检查" >> "$LOG"
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
  if test_three_times; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用成功（连续3次都通），保持 quic" >> "$LOG"
    rm -f "$FAIL_FLAG"
    rm -f "$CHECK_FAIL_FLAG"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') QUIC 试用失败，换回 http2" >> "$LOG"
    date +%s > "$FAIL_FLAG"
    set_proto http2
  fi
  exit 0
fi

echo "用法: $0 check | try-quic"
