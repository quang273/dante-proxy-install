#!/usr/bin/env bash
set -Eeuo pipefail

# =============== CẤU HÌNH NHANH (có thể override qua env) ===============
: "${TOKEN:=${BOT_TOKEN:-}}"
: "${CHAT:=${USER_ID:-}}"

: "${BASE_PREFIX:=socks-proj}"
: "${NEED_TOTAL:=3}"             # tổng project có billing muốn đạt
: "${TOKYO_COUNT:=4}"            # số VM Tokyo/project
: "${OSAKA_COUNT:=4}"            # số VM Osaka/project
: "${VM_PARALLEL:=8}"            # số VM tạo song song / project

: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"

: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"

# =============== LOG (đưa ra stderr để không lẫn dữ liệu) ===============
ts(){ date "+%F %T"; }
say(){ echo "[[$(ts)]] $*" >&2; }

trap 'say "❌ Lỗi tại dòng $LINENO"; exit 1' ERR

# =============== TIỆN ÍCH ===============
ensure_login(){
  if ! gcloud auth list --quiet >/dev/null 2>&1; then
    say "Đang đăng nhập gcloud…"
    gcloud auth login --quiet
  fi
}

get_default_project(){
  gcloud config get-value project 2>/dev/null || true
}

open_billing_pick(){
  # nếu đã set BILLING_ACCOUNT -> dùng luôn
  if [[ -n "${BILLING_ACCOUNT:-}" ]]; then
    echo "$BILLING_ACCOUNT"; return 0
  fi
  # chọn billing OPEN; nếu >1, ưu tiên cái đang gán cho project mặc định (nếu có)
  mapfile -t OPEN < <(gcloud billing accounts list --filter="OPEN=True" --format="value(ACCOUNT_ID)" 2>/dev/null || true)
  [[ ${#OPEN[@]} -eq 0 ]] && { echo ""; return 0; }

  local def; def="$(get_default_project)"
  if [[ -n "$def" ]]; then
    local acc
    acc="$(gcloud beta billing projects describe "$def" --format="value(billingAccountName)" 2>/dev/null || true)"
    acc="${acc##*/}"
    if [[ -n "$acc" ]]; then
      for a in "${OPEN[@]}"; do [[ "$a" == "$acc" ]] && { echo "$a"; return 0; }; done
    fi
  fi
  echo "${OPEN[0]}"
}

billing_enabled(){
  local pid="$1"
  local st
  st="$(gcloud beta billing projects describe "$pid" --format="value(billingEnabled)" 2>/dev/null || true)"
  [[ "$st" == "True" ]] && return 0 || return 1
}

ensure_billing(){
  local pid="$1"
  if billing_enabled "$pid"; then return 0; fi
  local ba; ba="$(open_billing_pick)"
  [[ -z "$ba" ]] && { say "⚠️  Không tìm thấy Billing Account OPEN để gán cho $pid"; return 1; }
  say "[$pid] Gán billing $ba…"
  gcloud beta billing projects link "$pid" --billing-account="$ba" --quiet
}

ensure_core_apis(){
  local pid="$1"
  local svcs=(serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com)
  for svc in "${svcs[@]}"; do
    local n=0
    until gcloud services enable "$svc" --project="$pid" --quiet; do
      n=$((n+1)); [[ $n -ge 6 ]] && { say "[$pid] ❌ enable $svc thất bại"; return 1; }
      sleep 4
    done
  done
  # chờ compute ready (propagate)
  for _ in {1..12}; do
    gcloud services list --enabled --project="$pid" \
      --filter="NAME=compute.googleapis.com" --format="value(NAME)" \
      | grep -q '^compute.googleapis.com$' && break
    sleep 3
  done
  say "[$pid] ✓ APIs sẵn sàng."
}

create_fw(){
  local pid="$1" port="$2" tag="$3"
  if ! gcloud compute firewall-rules describe allow-socks --project="$pid" >/dev/null 2>&1; then
    say "[$pid] Tạo firewall allow-socks tcp:${port}"
    gcloud compute firewall-rules create allow-socks \
      --project="$pid" --network=default --direction=INGRESS --priority=1000 \
      --action=ALLOW --rules="tcp:${port}" --source-ranges=0.0.0.0/0 \
      --target-tags="$tag" --quiet
  fi
}

startup_script_file(){
  local f="/tmp/danted_startup.sh"
  if [[ -f "$f" ]]; then echo "$f"; return 0; fi
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

# chọn interface tự động
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
  # nếu đã tồn tại → trả IP
  if gcloud compute instances describe "$name" --project="$pid" --zone="$zone" --format="value(name)" >/dev/null 2>&1; then
    gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
      --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
    return 0
  fi
  local sf; sf="$(startup_script_file)"
  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --tags="$TAG" \
    --metadata=USR="$PROXY_USER",PWD="$PROXY_PASS",PRT="$PROXY_PORT" \
    --metadata-from-file startup-script="$sf" \
    --quiet >/dev/null
  gcloud compute instances describe "$name" --project="$pid" --zone="$zone" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
}

tcp_open(){
  local ip="$1" port="$2" tries="${3:-20}" wait_s="${4:-3}"
  for _ in $(seq 1 "$tries"); do
    if timeout 2 bash -lc ":</dev/tcp/${ip}/${port}" 2>/dev/null; then
      return 0
    fi
    sleep "$wait_s"
  done
  return 1
}

send_tg(){
  local text="$1"
  [[ -z "$TOKEN" || -z "$CHAT" ]] && return 0
  curl -sS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="${CHAT}" --data-urlencode "text=${text}" >/dev/null || true
}

zones_tokyo=("asia-northeast1-a" "asia-northeast1-b" "asia-northeast1-c")
zones_osaka=("asia-northeast2-a" "asia-northeast2-b" "asia-northeast2-c")

deploy_project(){
  local pid="$1"
  say "==== Triển khai cho project: $pid ===="
  ensure_core_apis "$pid"
  create_fw "$pid" "$PROXY_PORT" "$TAG"

  # danh sách VM mong muốn
  mapfile -t VMS < <(for i in $(seq 1 "$TOKYO_COUNT"); do echo "proxy-tokyo-$i"; done; for i in $(seq 1 "$OSAKA_COUNT"); do echo "proxy-osaka-$i"; done)

  export -f create_vm startup_script_file
  export MACHINE_TYPE IMAGE_FAMILY IMAGE_PROJECT PROXY_USER PROXY_PASS PROXY_PORT TAG

  # tạo VM song song
  printf "%s\n" "${VMS[@]}" | xargs -I{} -P "$VM_PARALLEL" bash -lc '
    vm="{}"
    if [[ "$vm" == proxy-tokyo-* ]]; then
      arr=("${zones_tokyo[@]}")
    else
      arr=("${zones_osaka[@]}")
    fi
    zone="${arr[$RANDOM % ${#arr[@]}]}"
    ip="$(create_vm "'"$pid"'" "$vm" "$zone" || true)"
    echo "$vm,$zone,$ip"
  ' | {
    healthy=()
    while IFS=, read -r _vm _zone ip; do
      [[ -z "${ip:-}" ]] && continue
      if tcp_open "$ip" "$PROXY_PORT" 20 3; then
        healthy+=("${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}")
      fi
    done
    if ((${#healthy[@]})); then
      send_tg "Project: ${pid}%0A$(printf '%s\n' "${healthy[@]}" | tr '\n' '%0A')"
      say "[$pid] ✓ Healthy: ${#healthy[@]} / ${#VMS[@]}"
    else
      send_tg "Project: ${pid}%0AKhông proxy nào pass health-check (thử lại sau 1–2 phút)."
      say "[$pid] ⚠️  Chưa có proxy healthy."
    fi
  }
}

export -f say ts deploy_project ensure_core_apis create_fw tcp_open create_vm startup_script_file send_tg
export MACHINE_TYPE IMAGE_FAMILY IMAGE_PROJECT PROXY_USER PROXY_PASS PROXY_PORT TAG VM_PARALLEL TOKYO_COUNT OSAKA_COUNT
declare -a zones_tokyo zones_osaka
export zones_tokyo zones_osaka

# =============== MAIN ===============
say "BẮT ĐẦU: tự cân nhắc 2 hoặc 3 project; tránh lỗi billing/quota; tạo proxy & Telegram."

ensure_login

# 1) Thu thập danh sách project có billing
mapfile -t ALL < <(gcloud projects list --format="value(projectId)" 2>/dev/null || true)
with_billing=()
for p in "${ALL[@]}"; do
  billing_enabled "$p" && with_billing+=("$p")
done

# Ưu tiên: nếu default project có billing, giữ nó trong danh sách
defp="$(get_default_project || true)"
if [[ -n "$defp" ]] && billing_enabled "$defp"; then
  say "✓ Project mặc định có billing: $defp"
  # thêm vào đầu mảng (nếu chưa có)
  tmp=("$defp")
  for x in "${with_billing[@]}"; do [[ "$x" != "$defp" ]] && tmp+=("$x"); done
  with_billing=("${tmp[@]}")
fi

# 2) Nếu < NEED_TOTAL project có billing → tạo thêm
if ((${#with_billing[@]} < NEED_TOTAL)); then
  say "Hiện có: ${#with_billing[@]}/${NEED_TOTAL} project có billing. Cần tạo thêm $((NEED_TOTAL - ${#with_billing[@]}))."
  # tạo đến khi đủ
  needed=$((NEED_TOTAL - ${#with_billing[@]}))
  ba="$(open_billing_pick)"
  if [[ -z "$ba" ]]; then
    say "⚠️  Không có Billing Account OPEN để tạo mới. Sẽ dùng số project hiện có: ${#with_billing[@]}."
  else
    for i in $(seq 1 "$needed"); do
      rid="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
      pid="${BASE_PREFIX}-${rid}"
      say "Tạo project: $pid"
      gcloud projects create "$pid" --quiet
      gcloud services enable cloudapis.googleapis.com --project="$pid" --quiet || true
      gcloud beta billing projects link "$pid" --billing-account="$ba" --quiet
      # bật trước 2 API nền tảng để khi triển khai nhanh hơn
      gcloud services enable serviceusage.googleapis.com iam.googleapis.com --project="$pid" --quiet || true
      with_billing+=("$pid")
    done
  fi
fi

# 3) Chốt danh sách triển khai: lấy tối đa NEED_TOTAL project có billing (ưu tiên có tên base_prefix + default)
#    Không bao giờ đụng tới project KHÔNG billing.
deploy_list=()

# ưu tiên các project prefix (nếu có)
for p in "${with_billing[@]}"; do
  [[ "${#deploy_list[@]}" -ge "$NEED_TOTAL" ]] && break
  if [[ "$p" == ${BASE_PREFIX}-* ]]; then deploy_list+=("$p"); fi
done
# chèn default nếu có và chưa đủ
if [[ -n "$defp" ]] && billing_enabled "$defp"; then
  found=0; for d in "${deploy_list[@]}"; do [[ "$d" == "$defp" ]] && { found=1; break; }; done
  if ((found==0)) && ((${#deploy_list[@]} < NEED_TOTAL)); then deploy_list+=("$defp"); fi
fi
# lấp đủ từ phần còn lại
for p in "${with_billing[@]}"; do
  [[ "${#deploy_list[@]}" -ge "$NEED_TOTAL" ]] && break
  skip=0; for d in "${deploy_list[@]}"; do [[ "$d" == "$p" ]] && { skip=1; break; }; done
  ((skip==0)) && deploy_list+=("$p")
done

# nếu vẫn thiếu (không có billing đủ) → dùng những gì có
if ((${#deploy_list[@]}==0)); then
  say "⚠️  Không có project nào có billing. Dừng."
  exit 0
fi

say "Triển khai cho: ${deploy_list[*]}"

# 4) Triển khai song song theo project
printf "%s\n" "${deploy_list[@]}" | xargs -I{} -P "${#deploy_list[@]}" bash -lc 'deploy_project "$@"' _ {}

say "HOÀN TẤT."
