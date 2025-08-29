#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# CẤU HÌNH CÓ THỂ GÁN BẰNG ENV TRƯỚC KHI CHẠY
############################################
# Billing: nếu có >1 billing OPEN, PHẢI set BILLING_ACCOUNT="000000-AAAAAA-BBBBBB"
: "${BILLING_ACCOUNT:=}"                       # ví dụ: export BILLING_ACCOUNT="01FB6B-7E7C8D-FDC306"
: "${PARENT:=}"                                # ví dụ: --organization=123456789012 | --folder=345678901234 (để trống nếu cá nhân)
: "${BASE_PREFIX:=socks-proj-}"                # tiền tố tên project
: "${REQUIRED_PROJECTS:=3}"                    # cần đủ 3 project

# Thông số proxy
: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"

# Telegram (mặc định dùng đúng BOT/ID bạn đưa)
: "${BOT_TOKEN:=8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk}"
: "${USER_ID:=6666449775}"

# VM & vùng/khu vực
: "${TOKYO_COUNT:=4}"                          # asia-northeast1 (Tokyo)
: "${OSAKA_COUNT:=4}"                          # asia-northeast2 (Osaka)
: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"
: "${VM_PARALLEL:=8}"

TOKYO_ZONES=(asia-northeast1-a asia-northeast1-b asia-northeast1-c)
OSAKA_ZONES=(asia-northeast2-a asia-northeast2-b asia-northeast2-c)

# Firewall nguồn (nên siết lại IP của bạn khi xong PoC)
: "${SOURCE_RANGES:=0.0.0.0/0}"

############################################
# TIỆN ÍCH
############################################
ts(){ date "+[%F %T]"; }
log(){ echo "[$(ts)] $*"; }
need(){ command -v "$1" >/dev/null || { echo "Thiếu tool: $1"; exit 1; }; }
rand6(){ tr -dc 'a-z0-9' </dev/urandom | head -c 6; }
sanitize_id(){
  local s="$1"; s="${s,,}"; s="${s//[^a-z0-9-]/-}"
  s="${s#-}"; s="${s%-}"; while [[ "$s" == *"--"* ]]; do s="${s//--/-}"; done
  [[ "$s" =~ ^[a-z] ]] || s="p$s"; s="${s:0:30}"; s="${s%-}"
  ((${#s}>=6)) || s="${s}$(rand6)"; echo "$s"
}

need gcloud; need awk; need sed; need xargs; need curl

############################################
# STARTUP SCRIPT (cài Dante, fix external IFACE & auth)
############################################
startup_script() {
  cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

get_attr(){ curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || true; }

PROXY_USER="$(get_attr PROXY_USER)"; PROXY_PASS="$(get_attr PROXY_PASS)"; PROXY_PORT="$(get_attr PROXY_PORT)"
PROXY_USER="${PROXY_USER:-mr.quang}"; PROXY_PASS="${PROXY_PASS:-2703}"; PROXY_PORT="${PROXY_PORT:-1080}"

apt-get update -y
apt-get install -y dante-server curl

id -u "$PROXY_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$PROXY_USER"
echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" || true
[ -n "$IFACE" ] || IFACE="ens4"

cat >/etc/danted.conf <<CFG
logoutput: stderr
user.privileged: root
user.notprivileged: nobody
internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}
clientmethod: none
socksmethod: username
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks  pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
CFG

systemctl enable danted || true
systemctl restart danted || systemctl start danted || true

# Đợi cổng lắng nghe (best effort)
for i in {1..20}; do
  ss -lntp | grep -q ":${PROXY_PORT}\b" && break
  sleep 1
done
echo "DANTE_READY"
EOS
}

############################################
# BƯỚC 1: ĐẢM BẢO SẴN DỰ ÁN (3 project)
############################################
pick_billing() {
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    [[ "$BILLING_ACCOUNT" == billingAccounts/* ]] || BILLING_ACCOUNT="billingAccounts/${BILLING_ACCOUNT}"
    echo "$BILLING_ACCOUNT"; return
  fi
  local acc
  acc="$(gcloud beta billing accounts list --format="value(name)" --filter="open=true" | head -n1 || true)"
  [[ -n "$acc" ]] || { echo ""; return; }
  echo "$acc"
}

ensure_projects() {
  local want="$1" prefix="$2" parent_flag="" bill
  bill="$(pick_billing)"
  [[ -n "$PARENT" ]] && parent_flag="$PARENT"

  mapfile -t have < <(gcloud projects list --format="value(projectId)" | awk -v p="$prefix" 'index($0,p)==1')
  local n=${#have[@]}
  log "Đã có $n project với tiền tố \"$prefix\"."

  if (( n >= want )); then
    printf "%s\n" "${have[@]:0:want}"
    return
  fi

  local to_create=$((want - n))
  log "Cần tạo thêm $to_create project…"
  for i in $(seq 1 "$to_create"); do
    local id raw="${prefix}$i-$(rand6)"
    id="$(sanitize_id "$raw")"
    log "Tạo project: $id"
    gcloud projects create "$id" ${parent_flag:+$parent_flag} --quiet
    if [[ -n "$bill" ]]; then
      log "Gán billing: $bill → $id"
      gcloud beta billing projects link "$id" --billing-account="$bill" --quiet || true
    else
      log "⚠️  Không tìm thấy Billing OPEN – bạn nên export BILLING_ACCOUNT rồi chạy lại."
    fi
    have+=("$id")
  done
  printf "%s\n" "${have[@]:0:want}"
}

############################################
# BƯỚC 2: BẬT API + FIREWALL (idempotent)
############################################
enable_apis() {
  local pid="$1"
  gcloud services enable compute.googleapis.com iam.googleapis.com serviceusage.googleapis.com \
    --project="$pid" --quiet || true
}

ensure_firewall() {
  local pid="$1" port="$2" ranges="$3"
  gcloud compute firewall-rules describe allow-ssh --project="$pid" >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-ssh --project="$pid" --network=default \
    --direction=INGRESS --priority=1000 --action=ALLOW \
    --rules=tcp:22 --source-ranges=0.0.0.0/0 --quiet
  gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-socks --project="$pid" --network=default \
    --direction=INGRESS --priority=1000 --action=ALLOW \
    --rules="tcp:${port}" --source-ranges="${ranges}" \
    --target-tags="${TAG}" --quiet
}

############################################
# BƯỚC 3: TẠO VM (8/con project), IDP
############################################
create_vm(){
  local pid="$1" name="$2" zone="$3"
  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(name)" >/dev/null 2>&1 && { echo "EXISTING"; return 0; }

  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --tags="$TAG" \
    --metadata=PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT" \
    --metadata-from-file startup-script=<(startup_script) \
    --quiet >/dev/null
  echo "CREATED"
}

describe_ip(){
  local pid="$1" name="$2" zone="$3"
  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || true
}

health_check_ip(){
  local ip="$1"
  curl -m 15 -fsS -x "socks5h://${PROXY_USER}:${PROXY_PASS}@${ip}:${PROXY_PORT}" https://api.ipify.org >/dev/null
}

deploy_one_project(){
  local pid="$1"
  log "==== Project ${pid} ===="
  enable_apis "$pid"
  ensure_firewall "$pid" "$PROXY_PORT" "$SOURCE_RANGES"

  # danh sách 8 VM (4 Tokyo + 4 Osaka), rải zone
  local VMS=()
  for i in $(seq 1 "$TOKYO_COUNT"); do
    VMS+=("proxy-tokyo-$i|${TOKYO_ZONES[$(( (i-1) % ${#TOKYO_ZONES[@]} ))]}")
  done
  for i in $(seq 1 "$OSAKA_COUNT"); do
    VMS+=("proxy-osaka-$i|${OSAKA_ZONES[$(( (i-1) % ${#OSAKA_ZONES[@]} ))]}")
  done

  # tạo song song
  printf "%s\n" "${VMS[@]}" | xargs -I{} -P "${VM_PARALLEL}" bash -lc '
    IFS="|" read -r NAME ZONE <<<"{}";
    '"$(typeset -f startup_script)"'
    '"$(typeset -f create_vm)"'
    '"$(typeset -f log)"'
    RES="$(create_vm "'"$pid"'" "$NAME" "$ZONE")"
    log "[ '"$pid"' ] $NAME ($ZONE): $RES"
  '

  # chờ VM boot dịch vụ
  log "[${pid}] Đợi Dante khởi động…"; sleep 25

  # lấy IP + test
  local lines out ip name zone
  for pair in "${VMS[@]}"; do
    IFS="|" read -r name zone <<<"$pair"
    ip="$(describe_ip "$pid" "$name" "$zone")"
    [[ -z "$ip" ]] && continue
    if health_check_ip "$ip"; then
      out+="${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}\n"
    else
      out+="#FAIL ${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}\n"
    fi
  done

  # gửi 1 TIN NHẮN DUY NHẤT / PROJECT
  if [[ -n "${out:-}" ]]; then
    local msg
    msg="$(printf "Project: %s\n%s" "$pid" "$(printf "%b" "$out")")"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
         -d chat_id="${USER_ID}" --data-urlencode "text=${msg}" >/dev/null || true
    log "[${pid}] Đã gửi Telegram."
  else
    log "[${pid}] Không thu được IP nào."
  fi
}

############################################
# MAIN
############################################
log "BẮT ĐẦU: đảm bảo đủ $REQUIRED_PROJECTS project, gán billing nếu thiếu; tạo 8 proxy/project; gửi Telegram 1 tin/project."
mapfile -t TARGETS < <(ensure_projects "$REQUIRED_PROJECTS" "$BASE_PREFIX")
log "Triển khai cho: ${TARGETS[*]}"

for P in "${TARGETS[@]}"; do
  deploy_one_project "$P"
done

log "HOÀN TẤT."
