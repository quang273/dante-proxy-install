# ===================== regproxygg.sh (fixed) =====================
#!/usr/bin/env bash
set -Eeuo pipefail

# ===== CONFIG (có thể override qua env) =====
: "${NEED_TOTAL:=3}"              # muốn tối đa 3 project có billing
: "${TOKYO_WANT:=4}"              # số VM Tokyo / project (tối đa theo quota)
: "${OSAKA_WANT:=4}"              # số VM Osaka / project
: "${VM_PARALLEL:=6}"             # job song song khi tạo VM (>=1)
(( VM_PARALLEL>0 )) || VM_PARALLEL=1

: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"

: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"

# Telegram (nếu có)
: "${BOT_TOKEN:=}"
: "${USER_ID:=}"

TOKYO_REGION="asia-northeast1"
OSAKA_REGION="asia-northeast2"
TOKYO_ZONES=(asia-northeast1-a asia-northeast1-b asia-northeast1-c)
OSAKA_ZONES=(asia-northeast2-a asia-northeast2-b asia-northeast2-c)

ts(){ date "+%F %T"; }
say(){ echo "[[$(ts)]] $*" >&2; }
send_tg(){ [[ -n "$BOT_TOKEN" && -n "$USER_ID" ]] || return 0
  local title="$1"; shift; local body="${*:-}"
  curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=${title}" >/dev/null || true
  [[ -n "$body" ]] || return 0
  curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=${body}" >/dev/null || true
}

trap 'say "❌ Lỗi tại dòng $LINENO"; exit 1' ERR

# ---------- Helpers ----------
default_project(){ gcloud config get-value project 2>/dev/null | sed 's/(unset)//g' | xargs || true; }

enable_services(){
  local p="$1"
  local -a svcs=(serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com)
  for s in "${svcs[@]}"; do
    local tries=0
    while (( tries<5 )); do
      if gcloud services enable "$s" --project="$p" >/dev/null 2>&1; then
        break
      fi
      tries=$((tries+1))
      sleep $((tries*2))
    done
  done
}

ensure_firewall(){
  local p="$1"
  if ! gcloud compute firewall-rules describe allow-socks --project "$p" >/dev/null 2>&1; then
    gcloud compute firewall-rules create allow-socks \
      --project="$p" --network=default \
      --allow="tcp:${PROXY_PORT}" --direction=INGRESS \
      --priority=1000 --target-tags="${TAG}" >/dev/null
  fi
}

startup_script_prepare(){
  cat >/tmp/danted_startup.sh <<'EOS'
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

cat >/etc/danted.conf <<CONF
logoutput: syslog
internal: $IFACE port = $PRT
external: $IFACE
socksmethod: username
user.privileged: root
user.unprivileged: nobody
clientmethod: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: bind connect udpassociate
  log: connect error
}
CONF

systemctl enable danted
systemctl restart danted
EOS
  chmod +x /tmp/danted_startup.sh
}

vm_exists(){
  local p="$1" name="$2"
  gcloud compute instances list --project "$p" \
    --filter="name=${name}" --format="value(name)" | grep -qx "${name}"
}

create_vm(){
  local p="$1" name="$2" zone="$3"
  if vm_exists "$p" "$name"; then
    say "• [$p] Bỏ qua ${name} (đã tồn tại)"
    return 0
  fi
  gcloud compute instances create "$name" \
    --project "$p" --zone "$zone" \
    --machine-type "$MACHINE_TYPE" \
    --image-family "$IMAGE_FAMILY" --image-project "$IMAGE_PROJECT" \
    --tags "$TAG" \
    --metadata "USR=${PROXY_USER},PWD=${PROXY_PASS},PRT=${PROXY_PORT}" \
    --metadata-from-file startup-script=/tmp/danted_startup.sh \
    --quiet >/dev/null
}

# quota_free REGION per metric
quota_free_region(){
  local p="$1" region="$2" metric="$3"
  # metric: IN_USE_ADDRESSES | INSTANCES
  local json
  json="$(gcloud compute regions describe "$region" --project="$p" --format=json)"
  local lim; local use
  lim="$(jq -r ".quotas[] | select(.metric==\"${metric}\") | .limit" <<<"$json" 2>/dev/null || echo 0)"
  use="$(jq -r ".quotas[] | select(.metric==\"${metric}\") | .usage" <<<"$json" 2>/dev/null || echo 0)"
  awk -v L="${lim:-0}" -v U="${use:-0}" 'BEGIN{d=L-U; if(d<0)d=0; print int(d)}'
}

plan_counts(){
  local p="$1" want_tok="$2" want_osa="$3"
  local free_tok_addr free_tok_inst free_osa_addr free_osa_inst
  free_tok_addr=$(quota_free_region "$p" "$TOKYO_REGION" IN_USE_ADDRESSES)
  free_tok_inst=$(quota_free_region "$p" "$TOKYO_REGION" INSTANCES)
  free_osa_addr=$(quota_free_region "$p" "$OSAKA_REGION" IN_USE_ADDRESSES)
  free_osa_inst=$(quota_free_region "$p" "$OSAKA_REGION" INSTANCES)
  local tok osa
  # mỗi VM cần 1 instance + 1 address
  tok=$(( want_tok < free_tok_addr ? want_tok : free_tok_addr ))
  tok=$(( tok < free_tok_inst ? tok : free_tok_inst ))
  osa=$(( want_osa < free_osa_addr ? want_osa : free_osa_addr ))
  osa=$(( osa < free_osa_inst ? osa : free_osa_inst ))
  echo "${tok} ${osa}"
}

# tạo nhiều VM song song có giới hạn
create_many(){
  local p="$1" prefix="$2" count="$3"; shift 3
  local -a ZONES=("$@")
  local created=0 running=0 i zone_idx
  local zc="${#ZONES[@]}"; (( zc>0 )) || return 0
  for (( i=1; i<=count; i++ )); do
    zone_idx=$(( (i-1) % zc ))
    name="${prefix}-${i}"
    zone="${ZONES[$zone_idx]}"
    ( create_vm "$p" "$name" "$zone" && echo OK || echo FAIL ) &
    running=$((running+1))
    # giới hạn song song
    if (( running >= VM_PARALLEL )); then
      wait -n && running=$((running-1))
    fi
  done
  # đợi phần còn lại
  while (( running>0 )); do wait -n || true; running=$((running-1)); done

  # đếm số đã tạo (tồn tại)
  created=$(gcloud compute instances list --project "$p" \
    --filter="name~^${prefix}- AND tags.items=${TAG}" --format="value(name)" | wc -l)
  echo "$created"
}

health_and_collect(){
  local p="$1"
  gcloud compute instances list --project "$p" \
    --filter="status=RUNNING AND tags.items=${TAG}" \
    --format="value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)" \
  | while read -r name zone ip; do
      if timeout 3 bash -lc ":</dev/tcp/${ip}/${PROXY_PORT}" 2>/dev/null; then
        printf "✅ %s:%s:%s:%s (%s)\n" "$ip" "$PROXY_PORT" "$PROXY_USER" "$PROXY_PASS" "$name"
      else
        printf "❌ %s (port %s closed) (%s)\n" "$ip" "$PROXY_PORT" "$name"
      fi
    done
}

# lấy danh sách project có billingEnabled=True
billed_projects(){
  # lọc ra những project truy cập được và có billing
  local p
  gcloud projects list --format="value(projectId)" \
  | while read -r p; do
      be=$(gcloud beta billing projects describe "$p" --format="value(billingEnabled)" 2>/dev/null || echo "")
      [[ "$be" == "True" ]] && echo "$p"
    done
}

deploy_one(){
  local p="$1"
  say "==== Triển khai cho project: $p ===="
  enable_services "$p"
  say "[$p] ✓ APIs sẵn sàng."
  ensure_firewall "$p"
  startup_script_prepare

  read -r tok_plan osa_plan < <(plan_counts "$p" "$TOKYO_WANT" "$OSAKA_WANT")
  say "[$p] quota-plan: Tokyo=${tok_plan} | Osaka=${osa_plan}"
  if (( tok_plan==0 && osa_plan==0 )); then
    say "[$p] ⚠️  Không còn quota để tạo VM."
  else
    tok_created=$(create_many "$p" "proxy-tokyo" "$tok_plan" "${TOKYO_ZONES[@]}") || tok_created=0
    osa_created=$(create_many "$p" "proxy-osaka" "$osa_plan" "${OSAKA_ZONES[@]}") || osa_created=0
    say "[$p] Đã tạo: Tokyo=${tok_created} | Osaka=${osa_created}"
  fi

  sleep 5
  RES="$(health_and_collect "$p")"
  say "[$p] Kết quả:\n${RES:-"(trống)"}"
  send_tg "Project: ${p}" "Tokyo plan=${tok_plan} / Osaka plan=${osa_plan}\n${RES:-"(no VMs)"}"
}

main(){
  say "BẮT ĐẦU: tự chọn ≤${NEED_TOTAL} project đã có billing; tạo proxy & gửi Telegram."
  local defp; defp="$(default_project)"
  if [[ -z "$defp" ]]; then
    say "⚠️  Chưa chọn project mặc định (gcloud config set project <ID>). Vẫn tiếp tục nếu tìm thấy project có billing."
  else
    say "✓ Project mặc định: ${defp}"
  fi

  mapfile -t BILLED < <(billed_projects)
  if (( ${#BILLED[@]}==0 )); then
    say "⚠️  Không có project nào đã gán billing (hoặc không có quyền xem). Dừng."
    exit 0
  fi

  # ưu tiên project mặc định đứng đầu
  if [[ -n "$defp" ]]; then
    BILLED=($(printf "%s\n" "${BILLED[@]}" | awk -v d="$defp" '{a[$0]=1} END{if(a[d]){print d} }') \
             $(printf "%s\n" "${BILLED[@]}" | awk -v d="$defp" '$0!=d'))
  fi
  # lấy tối đa NEED_TOTAL
  local pick=()
  for p in "${BILLED[@]}"; do
    pick+=("$p")
    (( ${#pick[@]} >= NEED_TOTAL )) && break
  done
  say "Triển khai cho: ${pick[*]}"

  # chạy song song từng project (trong cùng shell → thấy được hàm)
  pids=()
  for p in "${pick[@]}"; do
    ( deploy_one "$p" ) & pids+=($!)
  done
  ok=0 fail=0
  for pid in "${pids[@]}"; do
    if wait "$pid"; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done
  say "HOÀN TẤT. OK=${ok} FAIL=${fail}"
}

main
# =================== end of regproxygg.sh ===================
