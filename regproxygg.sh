#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# CẤU HÌNH MẶC ĐỊNH (có thể override bằng env)
############################################
: "${BASE_PREFIX:=socks-proj-}"       # tiền tố tên project
: "${NEEDED_PROJECTS:=3}"             # cần đủ bao nhiêu project
: "${BILLING_ACCOUNT:=}"              # 000000-AAAAAA-BBBBBB (nếu để trống sẽ tự dò cái OPEN đầu tiên)
: "${APIS_CSV:=compute.googleapis.com,iam.googleapis.com,serviceusage.googleapis.com}"

# Proxy/Dante
: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"
: "${SOURCE_RANGES:=0.0.0.0/0}"       # firewall nguồn; nên siết về IP của bạn

# VM
: "${TOKYO_COUNT:=4}"                 # asia-northeast1
: "${OSAKA_COUNT:=4}"                 # asia-northeast2
: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"

# Gửi Telegram (mỗi project 1 tin)
: "${BOT_TOKEN:=8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk}"
: "${USER_ID:=6666449775}"

# Song song vừa đủ an toàn
: "${VM_PARALLEL:=6}"

############################################
# TIỆN ÍCH
############################################
ts(){ date "+[%F %T]"; }
log(){ printf "[%s] %s\n" "$(ts)" "$*" >&2; }
need(){ command -v "$1" >/dev/null || { echo "Thiếu tool: $1"; exit 1; }; }
need gcloud; need awk; need sed; need curl

rand6(){ tr -dc 'a-z0-9' </dev/urandom | head -c 6; }

get_billing(){
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    # Chuẩn hoá về ID dạng 000000-AAAAAA-BBBBBB
    echo "$BILLING_ACCOUNT"
    return 0
  fi
  local acc
  acc="$(gcloud billing accounts list --format="value(ACCOUNT_ID)" --filter="OPEN=True" 2>/dev/null | head -n1 || true)"
  echo "$acc"
}

enable_apis(){
  local pid="$1" csv="$2"
  IFS=',' read -r -a arr <<<"$csv"
  if [[ ${#arr[@]} -gt 0 ]]; then
    log "[$pid] Enable APIs: ${arr[*]}"
    gcloud services enable "${arr[@]}" --project="$pid" --quiet
  fi
}

ensure_firewall(){
  local pid="$1" port="$2" ranges="$3"
  if ! gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1; then
    log "[$pid] Tạo firewall allow-socks tcp:${port} ranges=${ranges}"
    gcloud compute firewall-rules create allow-socks \
      --project="$pid" --network=default --direction=INGRESS \
      --priority=1000 --action=ALLOW --rules="tcp:${port}" \
      --source-ranges="${ranges}" --target-tags="${TAG}" --quiet
  fi
}

startup_script() { cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

get_attr(){ curl -fsH "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }
PUSER="$(get_attr PROXY_USER)"; PPASS="$(get_attr PROXY_PASS)"; PPORT="$(get_attr PROXY_PORT)"
PUSER="${PUSER:-mr.quang}"; PPASS="${PPASS:-2703}"; PPORT="${PPORT:-1080}"

apt-get update -y
apt-get install -y dante-server curl

id -u "$PUSER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$PUSER"
echo "${PUSER}:${PPASS}" | chpasswd

# Giao diện OUT
IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[ -n "$IFACE" ] || IFACE="ens4"

# Cấu hình Dante: dùng socksmethod (method cũ đã deprecated)
cat >/etc/danted.conf <<CFG
logoutput: stderr
user.privileged: root
user.notprivileged: nobody
internal: 0.0.0.0 port = ${PPORT}
external: ${IFACE}
clientmethod: none
socksmethod: username
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
CFG

systemctl enable danted || true
systemctl restart danted || systemctl start danted || true

# Chờ lắng nghe cổng
for i in {1..20}; do
  if ss -lntp | grep -q ":${PPORT}\b"; then
    echo "DANTE_READY"
    exit 0
  fi
  sleep 1
done
echo "DANTE_START_TIMEOUT"
exit 0
EOS
}

create_vm(){
  local pid="$1" name="$2" zone="$3"
  local ip=""
  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --tags="$TAG" \
    --metadata=PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT" \
    --metadata-from-file startup-script=<(startup_script) \
    --quiet >/dev/null

  # Lấy IP ngoài
  for _ in {1..6}; do
    ip="$(gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
         --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
    sleep 3
  done
  echo "$ip"
}

# Health-check qua SOCKS5 đến api.ipify.org
hc_socks(){
  local ip="$1" port="$2" user="$3" pass="$4"
  curl -m 20 -fsS -x "socks5h://${user}:${pass}@${ip}:${port}" https://api.ipify.org >/dev/null
}

send_tele(){
  local text="$1"
  [[ -n "$BOT_TOKEN" && -n "$USER_ID" ]] || return 0
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
       -d chat_id="${USER_ID}" --data-urlencode "text=${text}" >/dev/null || true
}

ensure_projects(){
  # Lấy project hiện có với prefix
  mapfile -t existing < <(gcloud projects list --format="value(projectId)" \
                         | awk -v pfx="$BASE_PREFIX" 'index($0,pfx)==1{print $0}')
  local need="${NEEDED_PROJECTS}"
  local have="${#existing[@]}"

  if (( have >= need )); then
    # Chỉ lấy đúng N project mới nhất theo tên cho ổn định
    mapfile -t PROJECTS < <(printf "%s\n" "${existing[@]}" | sort | head -n "$need")
    log "Đã có ${#PROJECTS[@]} project với tiền tố \"${BASE_PREFIX}\": ${PROJECTS[*]}"
    printf "%s\n" "${PROJECTS[@]}"
    return 0
  fi

  local BILL="$(get_billing)"
  if [[ -z "$BILL" ]]; then
    log "⚠️  Không tìm thấy Billing Account OPEN. Hãy export BILLING_ACCOUNT=000000-AAAAAA-BBBBBB rồi chạy lại."
    exit 1
  fi
  log "Sử dụng Billing Account: ${BILL}"

  # Tạo bổ sung
  local create_n=$(( need - have ))
  for i in $(seq 1 "$create_n"); do
    local pid="${BASE_PREFIX}${i}-$(rand6)"
    log "Tạo project: ${pid}"
    gcloud projects create "$pid" --quiet
    gcloud beta billing projects link "$pid" --billing-account="$BILL" --quiet
    enable_apis "$pid" "$APIS_CSV"
  done

  # Reload danh sách đủ N
  mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" \
                         | awk -v pfx="$BASE_PREFIX" 'index($0,pfx)==1{print $0}' \
                         | sort | head -n "$need")
  log "Danh sách project dùng để triển khai: ${PROJECTS[*]}"
  printf "%s\n" "${PROJECTS[@]}"
}

deploy_project(){
  local pid="$1"
  log "==== Triển khai cho project: ${pid} ===="
  ensure_firewall "$pid" "$PROXY_PORT" "$SOURCE_RANGES"

  # danh sách VM/zone
  local TOK=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
  local OSA=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")

  mapfile -t VMS < <(
    for i in $(seq 1 "$TOKYO_COUNT");  do echo "proxy-tokyo-${i}"; done
    for i in $(seq 1 "$OSAKA_COUNT");  do echo "proxy-osaka-${i}"; done
  )

  # tạo VMs (song song vừa đủ)
  tmp_csv="/tmp/${pid}_vms.csv"; : > "$tmp_csv"
  printf "%s\n" "${VMS[@]}" | xargs -I{} -P "${VM_PARALLEL}" bash -lc '
    set -euo pipefail
    vm="{}"
    if [[ "$vm" == proxy-tokyo-* ]]; then
      zones=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
    else
      zones=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")
    fi
    # phân phối đều theo tên để tránh random lệch
    idx="${vm##*-}"; idx=$(( (idx - 1) % 3 ))
    zone="${zones[$idx]}"

    ip="$(gcloud compute instances describe "$vm" --project="'"$pid"'" --zone="$zone" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
      ip="$(create_vm "'"$pid"'" "$vm" "$zone" || true)"
    fi
    echo "${vm},${zone},${ip}"
  ' >> "$tmp_csv"

  # health check và soạn tin
  local ok_lines=() ; local all_lines=()
  while IFS=',' read -r vm z ip; do
    [[ -z "${ip:-}" ]] && continue
    all_lines+=("${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}")
    if hc_socks "$ip" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS"; then
      ok_lines+=("${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}")
    fi
  done < "$tmp_csv"

  if (( ${#ok_lines[@]} > 0 )); then
    send_tele "Project: ${pid}"
    send_tele "$(printf "%s\n" "${ok_lines[@]}")"
  else
    send_tele "Project: ${pid} — chưa có proxy pass health-check (dịch vụ vừa khởi động, đợi 1-2 phút thử lại)."
  fi

  log "[$pid] Tổng: ${#all_lines[@]} ; Healthy: ${#ok_lines[@]}"
}

############################################
# MAIN
############################################
log "BẮT ĐẦU: đảm bảo đủ ${NEEDED_PROJECTS} project, gán billing nếu thiếu; tạo 8 proxy/project; gửi Telegram 1 tin/project."

# 1) Lấy danh sách project đích
mapfile -t PROJECTS < <(ensure_projects)
log "Triển khai cho: ${PROJECTS[*]}"

# 2) Triển khai từng project
for P in "${PROJECTS[@]}"; do
  deploy_project "$P"
done

log "HOÀN TẤT."
