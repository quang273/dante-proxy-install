#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERR] died at line $LINENO"; exit 1' ERR

ts(){ date "+[[%F %T]]"; }
say(){ echo "$(ts) $*"; }
need(){ command -v "$1" >/dev/null || { echo "[ERR] thiếu tool: $1"; exit 1; }; }
need gcloud; need awk; need sed; need xargs; need curl

# ======= CẤU HÌNH MẶC ĐỊNH (có thể override qua env) =======
: "${BASE_PREFIX:=socks-proj}"             # tiền tố tên project
: "${NEEDED_PROJECTS:=3}"                  # đủ 3 project
: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"

# SOCKS5
: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"

# vùng / số VM
: "${TOKYO_COUNT:=4}"                      # asia-northeast1
: "${OSAKA_COUNT:=4}"                      # asia-northeast2
TOKYO_ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
OSAKA_ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")

# parallel
: "${PROJECT_PARALLEL:=3}"
: "${VM_PARALLEL:=8}"

# Firewall source (khuyên nên siết IP của bạn)
: "${SOURCE_RANGES:=0.0.0.0/0}"

# Telegram (override khi chạy)
: "${BOT_TOKEN:=}"
: "${USER_ID:=}"

# ======= TIỆN ÍCH =======
rand6(){ tr -dc a-z0-9 </dev/urandom | head -c 6; }
sanitize_id(){  # chuẩn hoá ID GCP
  local s="$1"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  s="${s#-}"; s="${s%-}"
  while [[ "$s" == *"--"* ]]; do s="${s//--/-}"; done
  [[ "$s" =~ ^[a-z] ]] || s="p$s"
  s="${s:0:30}"; s="${s%-}"
  [[ ${#s} -ge 6 ]] || s="${s}$(rand6)"
  echo "$s"
}

need_active_account(){
  local acc
  acc="$(gcloud auth list --filter='status:ACTIVE' --format='value(account)')" || true
  [[ -n "$acc" ]] || { echo "[ERR] Chưa có account active. Chạy: gcloud auth login"; exit 1; }
  gcloud config set account "$acc" >/dev/null
}

pick_billing(){
  # cho phép preset BILLING_ACCOUNT=000000-AAAAAA-BBBBBB
  if [[ -n "${BILLING_ACCOUNT:-}" ]]; then
    echo "$BILLING_ACCOUNT"; return 0
  fi
  gcloud beta billing accounts list --format='value(ACCOUNT_ID)' --filter='OPEN=True' | head -n1
}

enable_core_apis(){
  local pid="$1"
  local svcs=(serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com)
  for svc in "${svcs[@]}"; do
    local n=0
    until gcloud services enable "$svc" --project="$pid" --quiet; do
      n=$((n+1)); [[ $n -ge 8 ]] && { echo "[ERR] $pid: enable $svc failed"; return 1; }
      sleep 5
    done
  done
  # đợi compute ENABLED
  for _ in {1..12}; do
    gcloud services list --enabled --project="$pid" \
      --filter="NAME=compute.googleapis.com" --format="value(NAME)" \
      | grep -q '^compute.googleapis.com$' && break
    sleep 3
  done
}

ensure_firewalls(){
  local pid="$1"
  gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-socks --project="$pid" --network=default \
    --direction=INGRESS --priority=1000 --action=ALLOW --rules="tcp:${PROXY_PORT}" \
    --source-ranges="${SOURCE_RANGES}" --target-tags="${TAG}" --quiet
}

telegram_send(){ # gửi 1 message / project
  local text="$1"
  [[ -n "$BOT_TOKEN" && -n "$USER_ID" ]] || return 0
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=${text}" >/dev/null || true
}

# ======= STARTUP-SCRIPT (cài Dante, fix interface) =======
startup_script(){ cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
U="$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_USER || echo mr.quang)"
P="$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_PASS || echo 2703)"
PORT="$(curl -fsH "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_PORT || echo 1080)"

apt-get update -y
apt-get install -y dante-server curl

id -u "$U" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$U"
echo "${U}:${P}" | chpasswd

IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$IFACE" ] || IFACE="ens4"

cat >/etc/danted.conf <<CFG
logoutput: stderr
user.privileged: root
user.notprivileged: nobody
internal: 0.0.0.0 port = ${PORT}
external: ${IFACE}
clientmethod: none
socksmethod: username
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
CFG

systemctl enable danted || true
systemctl restart danted || systemctl start danted || true

# chờ cổng lắng nghe
for _ in $(seq 1 30); do
  ss -lntp | grep -q ":${PORT}\b" && exit 0
  sleep 2
done
exit 0
EOS
}

create_vm(){
  local pid="$1" name="$2" zone="$3"
  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --tags="$TAG" \
    --metadata=PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT" \
    --metadata-from-file startup-script=<(startup_script) \
    --quiet >/dev/null
}

tcp_open(){
  local ip="$1" port="$2" tries="${3:-30}" wait_s="${4:-4}"
  for _ in $(seq 1 "$tries"); do
    timeout 2 bash -lc ":</dev/tcp/${ip}/${port}" 2>/dev/null && return 0
    sleep "$wait_s"
  done
  return 1
}

deploy_project(){
  local pid="$1"
  say "==== Triển khai cho project: ${pid} ===="
  enable_core_apis "$pid"
  ensure_firewalls "$pid"

  # Danh sách 8 VM
  mapfile -t VMS < <(
    for i in $(seq 1 "$TOKYO_COUNT"); do echo "proxy-tokyo-$i"; done
    for i in $(seq 1 "$OSAKA_COUNT"); do echo "proxy-osaka-$i"; done
  )

  # Tạo song song
  export -f create_vm startup_script
  export MACHINE_TYPE IMAGE_FAMILY IMAGE_PROJECT PROXY_USER PROXY_PASS PROXY_PORT TAG
  printf "%s\n" "${VMS[@]}" | xargs -I{} -P "${VM_PARALLEL}" bash -lc '
    vm="{}"
    if [[ "$vm" == proxy-tokyo-* ]]; then
      zones=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
    else
      zones=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")
    fi
    zone="${zones[$RANDOM % ${#zones[@]}]}"
    create_vm "'"$pid"'" "$vm" "$zone" || true
  '

  # lấy IP
  mapfile -t IPS < <(gcloud compute instances list --project="$pid" \
      --filter="status=RUNNING AND tags.items=$TAG" \
      --format="value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)")

  total=${#IPS[@]}
  ok_list=()

  # Health-check từng IP (đợi Dante lên + test socks5h)
  for line in "${IPS[@]}"; do
    ip="$(awk '{print $3}' <<<"$line")"
    [[ -z "$ip" ]] && continue
    # đợi cổng mở
    if tcp_open "$ip" "$PROXY_PORT" 30 4; then
      # test qua socks5h + cred
      if curl -m 20 -fsS -x "socks5h://${PROXY_USER}:${PROXY_PASS}@${ip}:${PROXY_PORT}" https://api.ipify.org >/dev/null; then
        ok_list+=("${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}")
      fi
    fi
  done

  say "[${pid}] Tổng: ${total} ; Healthy: ${#ok_list[@]}"
  if ((${#ok_list[@]})); then
    telegram_send "Project: ${pid}\n$(printf "%s\n" "${ok_list[@]}")"
  else
    telegram_send "Project: ${pid}\n# Chưa có proxy pass, thử lại sau vài phút."
  fi
}

# ======= MAIN =======
say "BẮT ĐẦU: đảm bảo đủ 3 project, gán billing nếu thiếu; tạo 8 proxy/project; gửi Telegram 1 tin/project."
need_active_account
BILLING_ACCOUNT="${BILLING_ACCOUNT:-$(pick_billing)}"
[[ -n "$BILLING_ACCOUNT" ]] || { say "⚠️  Không tìm thấy Billing Account OPEN. Hãy export BILLING_ACCOUNT=000000-AAAAAA-BBBBBB rồi chạy lại."; exit 1; }

# Lấy các project hiện có với prefix
mapfile -t HAVE < <(gcloud projects list --format='value(projectId)' | awk -v pfx="$BASE_PREFIX-" 'index($0,pfx)==1{print $0}')
say "Hiện có: ${#HAVE[@]} project với tiền tố \"${BASE_PREFIX}-\"."

# Nếu thiếu → tạo cho đủ
if ((${#HAVE[@]} < NEEDED_PROJECTS)); then
  need_more=$((NEEDED_PROJECTS - ${#HAVE[@]}))
  say "Cần tạo thêm ${need_more} project…"
  for _ in $(seq 1 "$need_more"); do
    pid="$(sanitize_id "${BASE_PREFIX}-$(rand6)")"
    say "Tạo project: $pid"
    gcloud projects create "$pid" --quiet
    gcloud beta billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet
    # bật API lõi trước để tránh lỗi propagate
    enable_core_apis "$pid"
    HAVE+=("$pid")
  done
fi

# Triển khai — chạy tuần tự theo từng project (ổn định hơn); bạn có thể tăng tốc bằng xargs -P nếu muốn
for P in "${HAVE[@]}"; do
  deploy_project "$P"
done

say "HOÀN TẤT."
