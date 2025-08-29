#!/usr/bin/env bash
set -Eeuo pipefail

########################
# CẤU HÌNH NHANH
########################
# Prefix các project mới (nếu cần tạo thêm)
BASE_PREFIX="${BASE_PREFIX:-socks-proj}"
# Số project mục tiêu (2 hoặc 3). Nếu đã đủ & có billing thì KHÔNG tạo thêm.
TARGET_PROJECTS="${TARGET_PROJECTS:-3}"

# VM / Proxy
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_USER="${SOCKS_USER:-mr.quang}"
SOCKS_PASS="${SOCKS_PASS:-2703}"
MACHINE="${MACHINE:-e2-micro}"
IMG_FAMILY="${IMG_FAMILY:-debian-12}"
IMG_PROJECT="${IMG_PROJECT:-debian-cloud}"
TAG="${TAG:-socks}"

# Location & số lượng
TOKYO_ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
OSAKA_ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")
TOKYO_COUNT="${TOKYO_COUNT:-4}"
OSAKA_COUNT="${OSAKA_COUNT:-4}"

# Song song
PROJECT_PARALLEL="${PROJECT_PARALLEL:-2}"   # số project xử lý song song
VM_PARALLEL="${VM_PARALLEL:-8}"             # số VM tạo song song / project

# Telegram
BOT_TOKEN="${BOT_TOKEN:-}"
USER_ID="${USER_ID:-}"

########################
# TIỆN ÍCH
########################
ts(){ date "+[%F %T]"; }
say(){ echo "[$(ts)] $*"; }
need(){ command -v "$1" >/dev/null || { echo "Thiếu tool: $1"; exit 1; }; }
need gcloud; need awk; need sed; need xargs; need curl; need tr; need shuf || true

trap 'echo "[ERR] died at line $LINENO"; exit 1' ERR

send_tg(){ 
  local title="$1"; shift; local body="${1:-}"
  [[ -n "$BOT_TOKEN" && -n "$USER_ID" ]] || return 0
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
       -d chat_id="${USER_ID}" --data-urlencode "text=${title}" >/dev/null || true
  [[ -n "$body" ]] && curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
       -d chat_id="${USER_ID}" --data-urlencode "text=${body}" >/dev/null || true
}

enable_core_apis(){
  # Bật serviceusage, iam, compute — có check trước + retry/backoff nhẹ
  local pid="$1"
  local svcs=(serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com)

  # check nhanh: compute đã bật chưa
  if gcloud services list --enabled --project="$pid" \
       --filter="NAME=compute.googleapis.com" --format="value(NAME)" \
       | grep -q '^compute.googleapis.com$'; then
    say "[$pid] ✓ APIs sẵn sàng (compute đã ENABLED)."
    return 0
  fi

  say "[$pid] Enable core APIs…"
  # enable cả 3 một lúc (gcloud cho phép nhiều service trong 1 lệnh)
  local tries=0
  until gcloud services enable "${svcs[@]}" --project="$pid" --quiet; do
    tries=$((tries+1))
    [[ $tries -ge 5 ]] && { say "[ERR] $pid: enable core APIs failed"; return 1; }
    sleep $((2*tries))
  done

  # poll đợi compute hiện ENABLED (tối đa ~60s)
  for _ in {1..20}; do
    if gcloud services list --enabled --project="$pid" \
         --filter="NAME=compute.googleapis.com" --format="value(NAME)" | grep -q '^compute.googleapis.com$'; then
      say "[$pid] ✓ APIs sẵn sàng."
      return 0
    fi
    sleep 3
  done
  say "[$pid] ⚠️ compute.googleapis.com chưa hiện ENABLED nhưng sẽ propagate tiếp."
}

create_fw(){
  local pid="$1"
  if ! gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1; then
    say "[$pid] Tạo firewall allow-socks tcp:${SOCKS_PORT}"
    gcloud compute firewall-rules create allow-socks \
      --project="$pid" --network=default \
      --direction=INGRESS --priority=1000 --action=ALLOW \
      --rules="tcp:${SOCKS_PORT}" \
      --source-ranges=0.0.0.0/0 --target-tags="${TAG}" --quiet || true
  fi
}

startup_script_file(){
  # Viết ra file tạm để metadata-from-file dùng chắc chắn (tránh subshell function export)
  local f="/tmp/danted_startup.$$.$RANDOM.sh"
  cat >"$f" <<'EOS'
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
  chmod +x "$f"
  echo "$f"
}

create_vm(){
  local pid="$1" name="$2" zone="$3"
  # Nếu tồn tại, trả IP luôn
  if gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
        --format="value(name)" >/dev/null 2>&1; then
    gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
    return 0
  fi

  local sfile; sfile="$(startup_script_file)"
  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" --machine-type="$MACHINE" \
    --image-family="$IMG_FAMILY" --image-project="$IMG_PROJECT" \
    --tags="$TAG" \
    --metadata=USR="$SOCKS_USER",PWD="$SOCKS_PASS",PRT="$SOCKS_PORT" \
    --metadata-from-file startup-script="$sfile" \
    --quiet >/dev/null || return 1

  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}

tcp_open(){
  local ip="$1" port="$2" tries="${3:-20}" wait_s="${4:-3}"
  for _ in $(seq 1 "$tries"); do
    if timeout 2 bash -c ":</dev/tcp/${ip}/${port}" 2>/dev/null; then
      return 0
    fi
    sleep "$wait_s"
  done
  return 1
}

deploy_project(){
  local pid="$1"
  say "==== Triển khai cho project: $pid ===="
  enable_core_apis "$pid" || { say "[$pid] BỎ QUA (chưa có billing hoặc API lỗi)"; return 0; }
  create_fw "$pid"

  # Danh sách 8 VM
  local VMS=()
  for i in $(seq 1 "$TOKYO_COUNT"); do VMS+=("proxy-tokyo-$i"); done
  for i in $(seq 1 "$OSAKA_COUNT"); do VMS+=("proxy-osaka-$i"); done

  # Tạo song song VM
  export -f create_vm
  export MACHINE IMG_FAMILY IMG_PROJECT TAG SOCKS_USER SOCKS_PASS SOCKS_PORT
  local tmpfile="/tmp/${pid}_vms.$$.$RANDOM.csv"
  printf "%s\n" "${VMS[@]}" \
  | xargs -I{} -P "$VM_PARALLEL" bash -c '
      PID="$1"; VM="$2"
      if [[ "$VM" == proxy-tokyo-* ]]; then
        ZONES=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
      else
        ZONES=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")
      fi
      ZONE="${ZONES[$RANDOM % ${#ZONES[@]}]}"
      IP="$(create_vm "$PID" "$VM" "$ZONE" || true)"
      echo "$VM,$ZONE,$IP"
    ' _ "$pid" {} >"$tmpfile"

  # Health-check & gửi Telegram
  local OUT=""; local ok=0; local total=0
  while IFS=, read -r vm zone ip; do
    [[ -z "${vm:-}" ]] && continue
    total=$((total+1))
    [[ -z "${ip:-}" ]] && continue
    if tcp_open "$ip" "$SOCKS_PORT"; then
      OUT+="${ip}:${SOCKS_PORT}:${SOCKS_USER}:${SOCKS_PASS}"$'\n'
      ok=$((ok+1))
    fi
  done < "$tmpfile"

  if [[ -n "$OUT" ]]; then
    send_tg "Project: ${pid}" "${OUT%$'\n'}"
  else
    send_tg "Project: ${pid}" "Không proxy nào pass health-check (có thể quota/propagate; thử lại sau)."
  fi
  say "[$pid] Tổng: $total ; Healthy: $ok"
}

########################
# QUẢN LÝ PROJECTS & BILLING
########################
get_default_project(){
  gcloud config get-value project 2>/dev/null || true
}

has_billing(){
  local pid="$1"
  gcloud beta billing projects describe "$pid" --format="value(billingEnabled)" 2>/dev/null \
    | grep -qi '^true$'
}

ensure_projects_with_billing(){
  # Trả ra danh sách project để deploy (tối đa TARGET_PROJECTS), ưu tiên project đã có billing
  local desired="$1" ; shift || true
  local default_proj; default_proj="$(get_default_project)"
  [[ -n "$default_proj" ]] && has_billing "$default_proj" && say "✓ Project mặc định có billing: $default_proj"

  # Lấy các project “socks-proj-*” & mọi project khả dụng
  mapfile -t all < <(gcloud projects list --format="value(projectId)" 2>/dev/null || true)
  [[ ${#all[@]} -eq 0 ]] && { echo ""; return 0; }

  # Lọc những project đã có billing
  local bill_ok=()
  for p in "${all[@]}"; do
    if has_billing "$p"; then bill_ok+=("$p"); fi
  done

  # Ưu tiên lấy default nếu có billing
  local selected=()
  if [[ -n "$default_proj" ]] && has_billing "$default_proj"; then
    selected+=("$default_proj")
  fi
  # Thêm các socks-proj-* có billing
  for p in "${bill_ok[@]}"; do
    [[ "$p" == "$default_proj" ]] && continue
    if [[ "$p" == "$BASE_PREFIX"* ]]; then
      selected+=("$p")
    fi
  done
  # Nếu thiếu, thêm các project khác có billing
  if [[ ${#selected[@]} -lt $desired ]]; then
    for p in "${bill_ok[@]}"; do
      [[ " ${selected[*]} " == *" $p "* ]] && continue
      selected+=("$p")
      [[ ${#selected[@]} -ge $desired ]] && break
    done
  fi

  # Nếu vẫn < desired ⇒ tạo thêm project mới & link billing nếu còn quota
  if [[ ${#selected[@]} -lt $desired ]]; then
    say "Cần tạo thêm $((desired - ${#selected[@]})) project…"
    # Lấy billing account OPEN đầu tiên
    local BA; BA="$(gcloud billing accounts list --format='value(ACCOUNT_ID)' --filter='OPEN=True' 2>/dev/null | head -n1 || true)"
    if [[ -z "$BA" ]]; then
      say "⚠️  Không tìm thấy Billing Account OPEN. Chỉ dùng các project đã có billing."
    fi
    local need=$((desired - ${#selected[@]}))
    for i in $(seq 1 "$need"); do
      local randsuf; randsuf="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
      local nid="${BASE_PREFIX}-${randsuf}-err-died-at"
      say "Tạo project: $nid"
      gcloud projects create "$nid" --quiet || continue
      # bật cloudapis trước khi link billing (thường gcloud tự làm, nhưng cho chắc)
      gcloud services enable cloudapis.googleapis.com --project="$nid" --quiet || true
      if [[ -n "$BA" ]]; then
        if gcloud beta billing projects link "$nid" --billing-account="$BA" --quiet; then
          selected+=("$nid")
        else
          say "⚠️  Link billing thất bại (hết quota?) cho $nid — bỏ qua."
        fi
      fi
    done
  fi

  # Cắt đúng desired & unique
  awk -v n="$desired" '{
    if(!seen[$0]++){ print $0; c++ }
    if (c>=n) exit
  }' < <(printf "%s\n" "${selected[@]}") || true
}

########################
# MAIN
########################
say "BẮT ĐẦU: tự cân nhắc 2 hay 3 project + tránh lỗi billing/quota; tạo proxy & gửi Telegram."

# Nếu người dùng chỉ định PROJECTS sẵn thì dùng luôn:
if [[ -n "${PROJECTS:-}" ]]; then
  mapfile -t TARGETS < <(printf "%s\n" ${PROJECTS})
else
  mapfile -t TARGETS < <(ensure_projects_with_billing "$TARGET_PROJECTS")
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  say "⚠️  Không có project nào sẵn sàng (có billing). Dừng."
  exit 0
fi
say "Triển khai cho: ${TARGETS[*]}"

# Chạy song song giữa các PROJECT
export -f deploy_project enable_core_apis create_fw tcp_open create_vm startup_script_file send_tg
export MACHINE IMG_FAMILY IMG_PROJECT TAG SOCKS_USER SOCKS_PASS SOCKS_PORT TOKYO_COUNT OSAKA_COUNT VM_PARALLEL BOT_TOKEN USER_ID

printf "%s\n" "${TARGETS[@]}" \
| xargs -I{} -P "${PROJECT_PARALLEL}" bash -c '
  PID="$1"
  deploy_project "$PID"
' _ {}

say "HOÀN TẤT."
