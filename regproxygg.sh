#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# CẤU HÌNH NHANH (có thể override qua env)
########################################
BASE_PREFIX="${BASE_PREFIX:-socks-proj-}"   # tiền tố project phụ
LABELS="${LABELS:-owner=proxy,env=prod}"

# Proxy
PORT="${PORT:-1080}"
PROXY_USER="${PROXY_USER:-mr.quang}"
PROXY_PASS="${PROXY_PASS:-2703}"

# VM & Image
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-12}"
IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"
TAG="${TAG:-socks}"

# Mỗi project: 2 Tokyo + 2 Osaka (để né quota 4 IP/region). Có thể đổi 1/1 nếu thiếu quota.
TOKYO_COUNT="${TOKYO_COUNT:-2}"
OSAKA_COUNT="${OSAKA_COUNT:-2}"
VM_PARALLEL="${VM_PARALLEL:-6}"

TOKYO_ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
OSAKA_ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")

# Telegram
: "${BOT_TOKEN:?Thiếu BOT_TOKEN}"
: "${USER_ID:?Thiếu USER_ID}"

# Billing: nếu không set BILLING_ACCOUNT, script sẽ auto-pick 1 account OPEN (nếu >1 sẽ chọn cái đầu tiên).
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

########################################
# TIỆN ÍCH
########################################
ts(){ date "+[%F %T]"; }
say(){ echo "$(ts) $*"; }
need(){ command -v "$1" >/dev/null || { echo "Thiếu tool: $1"; exit 1; }; }
need gcloud; need awk; need sed; need xargs; need curl

rand_suffix(){ tr -dc 'a-z0-9' </dev/urandom | head -c 6; }
sanitize_id(){
  local s="$1"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  s="${s#-}"; s="${s%-}"
  while [[ "$s" == *"--"* ]]; do s="${s//--/-}"; done
  [[ "$s" =~ ^[a-z] ]] || s="p$s"
  s="${s:0:30}"; s="${s%-}"
  [[ "${#s}" -lt 6 ]] && s="${s}$(rand_suffix)"
  echo "$s"
}

telegram_send(){ local t="$1"; shift; local body="${*:-}";
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=${t}" >/dev/null || true
  [[ -n "$body" ]] && curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=${body}" >/dev/null || true
}

ensure_billing_account(){
  [[ -n "$BILLING_ACCOUNT" ]] && return 0
  mapfile -t OPEN < <(gcloud billing accounts list --format="value(ACCOUNT_ID)" --filter="OPEN=True" || true)
  if [[ ${#OPEN[@]} -eq 0 ]]; then
    say "⚠️  Không tìm thấy Billing Account OPEN. Chỉ deploy trên project đã có billing."
    return 0
  fi
  BILLING_ACCOUNT="${OPEN[0]}"
  say "✓ Dùng Billing Account: $BILLING_ACCOUNT"
}

billing_enabled(){
  local pid="$1"
  gcloud beta billing projects describe "$pid" --format="value(billingEnabled)" 2>/dev/null | grep -qi '^true$'
}

link_billing_safe(){
  local pid="$1"
  if billing_enabled "$pid"; then
    say "[$pid] Billing đã bật."
    return 0
  fi
  [[ -z "$BILLING_ACCOUNT" ]] && { say "[$pid] Bỏ qua link billing (không có BILLING_ACCOUNT)."; return 1; }
  if ! gcloud beta billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet; then
    say "[$pid] ⚠️  Link billing thất bại (có thể quota exceeded). Bỏ qua."
    return 1
  fi
  say "[$pid] ✓ Đã link billing."
}

enable_core_apis(){
  local pid="$1"
  for svc in serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com; do
    local n=0
    until gcloud services enable "$svc" --project="$pid" --quiet; do
      n=$((n+1)); [[ $n -ge 6 ]] && { say "[$pid] ❌ enable $svc thất bại."; return 1; }
      sleep 5
    done
  done
  # chờ propagate
  for _ in {1..12}; do
    gcloud services list --enabled --project="$pid" \
      --filter="NAME=compute.googleapis.com" --format="value(NAME)" | grep -q '^compute.googleapis.com$' && break
    sleep 3
  done
  say "[$pid] ✓ APIs sẵn sàng."
}

create_firewall(){
  local pid="$1"
  gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-socks \
      --project="$pid" --allow="tcp:${PORT}" \
      --direction=INGRESS --priority=1000 --network=default \
      --source-ranges="0.0.0.0/0" --target-tags="$TAG" --quiet
}

# Viết startup-script ra file tạm
STARTUP_FILE="/tmp/danted_startup.sh"
cat > "$STARTUP_FILE" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y dante-server curl
USR="$(curl -fsH 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/USR || echo mr.quang)"
PWD="$(curl -fsH 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/PWD || echo 2703)"
PRT="$(curl -fsH 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/PRT || echo 1080)"
id -u "$USR" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$USR"
echo "${USR}:${PWD}" | chpasswd
IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'); IFACE="${IFACE:-ens4}"
cat >/etc/danted.conf <<CFG
logoutput: stderr
user.privileged: root
user.notprivileged: nobody
internal: 0.0.0.0 port = ${PRT}
external: ${IFACE}
clientmethod: none
socksmethod: username
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
CFG
systemctl enable danted || true
systemctl restart danted || systemctl start danted || true
EOS
chmod +x "$STARTUP_FILE"

create_vm(){
  local pid="$1" name="$2" zone="$3"
  # nếu đã có -> trả IP
  if gcloud compute instances describe "$name" --project="$pid" --zone="$zone" --format="value(name)" >/dev/null 2>&1; then
    gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)"; return 0
  fi
  # tạo mới
  if ! gcloud compute instances create "$name" \
      --project="$pid" --zone="$zone" \
      --machine-type="$MACHINE_TYPE" \
      --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
      --tags="$TAG" \
      --metadata=USR="$PROXY_USER",PWD="$PROXY_PASS",PRT="$PORT" \
      --metadata-from-file startup-script="$STARTUP_FILE" \
      --quiet >/dev/null; then
    # rớt vì quota region... trả rỗng
    echo ""; return 0
  fi
  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP))" 2>/dev/null || true
  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}

tcp_open(){
  local ip="$1" port="$2" tries="${3:-20}" wait_s="${4:-3}"
  for _ in $(seq 1 "$tries"); do
    timeout 2 bash -lc ":</dev/tcp/${ip}/${port}" 2>/dev/null && return 0
    sleep "$wait_s"
  done
  return 1
}

deploy_project(){
  set -Eeuo pipefail
  local pid="$1"
  say "==== Triển khai cho project: $pid ===="

  enable_core_apis "$pid" || { telegram_send "Project: ${pid}" "Enable APIs thất bại (thường do billing). Bỏ qua."; return 0; }
  create_firewall "$pid"

  # 2 Tokyo + 2 Osaka
  mapfile -t VMS < <(for i in $(seq 1 "$TOKYO_COUNT"); do echo "proxy-tokyo-$i"; done; \
                     for i in $(seq 1 "$OSAKA_COUNT"); do echo "proxy-osaka-$i"; done)

  export -f create_vm tcp_open
  export MACHINE_TYPE IMAGE_FAMILY IMAGE_PROJECT TAG PROXY_USER PROXY_PASS PORT STARTUP_FILE

  OUT=()
  printf "%s\n" "${VMS[@]}" | xargs -I{} -P "$VM_PARALLEL" bash -lc '
    VM="{}"
    if [[ "$VM" == proxy-tokyo-* ]]; then ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c"); else ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c"); fi
    ZONE="${ZONES[$RANDOM % ${#ZONES[@]}]}"
    IP="$(create_vm "'"$pid"'" "$VM" "$ZONE" || true)"
    echo "$VM,$ZONE,$IP"
  ' | while IFS=, read -r _vm _zone ip; do
        [[ -z "$ip" ]] && continue
        if tcp_open "$ip" "$PORT" 20 3; then
          OUT+=("${ip}:${PORT}:${PROXY_USER}:${PROXY_PASS}")
        fi
     done

  if [[ ${#OUT[@]} -gt 0 ]]; then
    telegram_send "Project: ${pid}" "$(printf "%s\n" "${OUT[@]}")"
  else
    telegram_send "Project: ${pid}" "Chưa proxy nào mở cổng (có thể do quota hoặc danted chưa ready). Thử lại sau 1–2 phút."
  fi
}

create_project_and_link(){
  local base="$1"
  local id="$(sanitize_id "${BASE_PREFIX}${base}-$(rand_suffix)")"
  say "Tạo project: $id"
  gcloud projects create "$id" --labels="$LABELS" --quiet
  # bật cloudapis để link billing
  gcloud services enable cloudapis.googleapis.com --project="$id" --quiet || true
  if link_billing_safe "$id"; then
    echo "$id"
  else
    # không link được billing ⇒ xoá cho sạch tránh lẫn
    say "[$id] Xoá project vì không link được billing."
    gcloud projects delete "$id" --quiet || true
    echo ""
  fi
}

########################################
# XÁC ĐỊNH BỘ 3 PROJECT MỤC TIÊU
########################################
say "BẮT ĐẦU: tự cân nhắc 2 hay 3 project + tránh lỗi billing/quota; tạo proxy & gửi Telegram."

# Project mặc định + billing?
CURR_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
DEFAULT_OK=false
if [[ -n "$CURR_PROJECT" ]] && billing_enabled "$CURR_PROJECT"; then
  DEFAULT_OK=true
  say "✓ Project mặc định có billing: $CURR_PROJECT"
else
  say "ℹ️  Project mặc định KHÔNG có billing hoặc chưa set."
fi

# Các socks-proj-* hiện có
mapfile -t EXIST < <(gcloud projects list --format="value(projectId)" | grep "^${BASE_PREFIX}" || true)

# Lọc các project có billing
TARGETS=()
if $DEFAULT_OK; then TARGETS+=("$CURR_PROJECT"); fi
for p in "${EXIST[@]:-}"; do
  billing_enabled "$p" && TARGETS+=("$p")
done

# Nếu đã đủ 3 thì dừng ở đây (không tạo thêm)
if [[ ${#TARGETS[@]} -ge 3 ]]; then
  say "✓ Đã có ≥3 project có billing: ${TARGETS[*]}"
else
  ensure_billing_account
  # cần bổ sung đến đủ 3
  NEED=$((3 - ${#TARGETS[@]}))
  if [[ $NEED -gt 0 ]]; then
    # nếu default không dùng được, có thể sẽ tạo 3
    for i in $(seq 1 "$NEED"); do
      NEWID="$(create_project_and_link "auto-$i")"
      [[ -n "$NEWID" ]] && TARGETS+=("$NEWID")
    done
  fi
fi

# Nếu vì quota billing mà <3, ta vẫn deploy trên những project có billing
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  say "❌ Không có project nào có billing. Kết thúc."
  exit 0
fi

# Loại trùng + giới hạn 3
# (giữ nguyên thứ tự: ưu tiên default (nếu có) + các socks-proj- đã có + mới tạo)
CLEAN=()
for p in "${TARGETS[@]}"; do
  [[ " ${CLEAN[*]-} " == *" $p "* ]] || CLEAN+=("$p")
done
while [[ ${#CLEAN[@]} -gt 3 ]]; do CLEAN=("${CLEAN[@]:0:3}"); done

say "Triển khai cho: ${CLEAN[*]}"

########################################
# TRIỂN KHAI
########################################
export -f enable_core_apis create_firewall deploy_project tcp_open create_vm
export MACHINE_TYPE IMAGE_FAMILY IMAGE_PROJECT TAG PROXY_USER PROXY_PASS PORT TOKYO_COUNT OSAKA_COUNT VM_PARALLEL STARTUP_FILE

for pid in "${CLEAN[@]}"; do
  deploy_project "$pid"
done

say "HOÀN TẤT."
