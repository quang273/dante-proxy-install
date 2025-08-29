#!/usr/bin/env bash
# ===================== regproxygg_v3.sh =====================
set -Eeuo pipefail

# ====== CONFIG ======
: "${NEED_TOTAL:=3}"              # luôn nhắm đủ 3 project
: "${TOKYO_WANT:=4}"
: "${OSAKA_WANT:=4}"
: "${VM_PARALLEL:=6}"
: "${MACHINE_TYPE:=e2-micro}"
: "${IMAGE_FAMILY:=debian-12}"
: "${IMAGE_PROJECT:=debian-cloud}"
: "${TAG:=socks}"
: "${PROXY_PORT:=1080}"
: "${PROXY_USER:=mr.quang}"
: "${PROXY_PASS:=2703}"

# BẮT BUỘC để gán billing cho cả 3
: "${BILLING_ACCOUNT:=}"          # ví dụ: 012345-6789AB-CDEF01

# (Tuỳ chọn) parent khi tạo project mới
: "${ORG_ID:=}"
: "${FOLDER_ID:=}"
: "${PROJECT_PREFIX:=proxy-gg}"

: "${BOT_TOKEN:=}"
: "${USER_ID:=}"

TOKYO_REGION="asia-northeast1"
OSAKA_REGION="asia-northeast2"
TOKYO_ZONES=(asia-northeast1-a asia-northeast1-b asia-northeast1-c)
OSAKA_ZONES=(asia-northeast2-a asia-northeast2-b asia-northeast2-c)
(( VM_PARALLEL>0 )) || VM_PARALLEL=1

ts(){ date "+%F %T"; }
say(){ echo "[[$(ts)]] $*" >&2; }

send_tg(){
  [[ -n "$BOT_TOKEN" && -n "$USER_ID" ]] || return 0
  curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${USER_ID}" --data-urlencode "text=$1" >/dev/null || true
}

need_bin(){ command -v "$1" >/dev/null 2>&1 || { say "Thiếu binary: $1"; exit 1; }; }

default_project(){ gcloud config get-value project 2>/dev/null | sed 's/(unset)//g' | xargs || true; }

enable_services(){
  local p="$1"
  gcloud services enable serviceusage.googleapis.com iam.googleapis.com compute.googleapis.com \
    --project="$p" >/dev/null
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

startup_script(){
  cat <<'EOS'
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
logoutput: syslog
internal: 0.0.0.0 port = ${PRT}
external: ${IFACE}
method: username none
user.notprivileged: nobody
clientmethod: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect error }
socksmethod: username
pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  command: connect bind udpassociate
  log: connect disconnect error
}
CFG
systemctl enable danted
systemctl restart danted
EOS
}

create_vm(){
  local p="$1" name="$2" zone="$3"
  if gcloud compute instances describe "$name" --zone "$zone" --project "$p" >/dev/null 2>&1; then
    say "[$p/$zone] VM đã tồn tại: $name -> bỏ qua"
    return 0
  fi
  local tmp_script; tmp_script="$(mktemp)"; startup_script > "$tmp_script"
  gcloud compute instances create "$name" \
    --project "$p" --zone "$zone" \
    --machine-type "$MACHINE_TYPE" \
    --image-family "$IMAGE_FAMILY" --image-project "$IMAGE_PROJECT" \
    --tags "$TAG" \
    --metadata-from-file startup-script="$tmp_script" \
    --metadata "USR=${PROXY_USER},PWD=${PROXY_PASS},PRT=${PROXY_PORT}" \
    --scopes "https://www.googleapis.com/auth/cloud-platform" \
    --quiet >/dev/null
  rm -f "$tmp_script"
}

quota_free_region(){
  local p="$1" region="$2" metric="$3"
  local json lim use
  json="$(gcloud compute regions describe "$region" --project="$p" --format=json)"
  lim="$(jq -r ".quotas[] | select(.metric==\"${metric}\") | .limit" <<<"$json" 2>/dev/null || echo 0)"
  use="$(jq -r ".quotas[] | select(.metric==\"${metric}\") | .usage" <<<"$json" 2>/dev/null || echo 0)"
  awk -v L="${lim:-0}" -v U="${use:-0}" 'BEGIN{d=L-U; if(d<0)d=0; print int(d)}'
}

plan_counts(){
  local p="$1" want_tok="$2" want_osa="$3"
  local tAddr tInst oAddr oInst tok osa
  tAddr=$(quota_free_region "$p" "$TOKYO_REGION" IN_USE_ADDRESSES)
  tInst=$(quota_free_region "$p" "$TOKYO_REGION" INSTANCES)
  oAddr=$(quota_free_region "$p" "$OSAKA_REGION" IN_USE_ADDRESSES)
  oInst=$(quota_free_region "$p" "$OSAKA_REGION" INSTANCES)
  tok=$(( want_tok < tAddr ? want_tok : tAddr )); tok=$(( tok < tInst ? tok : tInst ))
  osa=$(( want_osa < oAddr ? want_osa : oAddr )); osa=$(( osa < oInst ? osa : oInst ))
  echo "$tok $osa"
}

create_many(){
  local p="$1" prefix="$2" count="$3"; shift 3 || true
  local -a ZONES=("$@")
  local running=0 zc="${#ZONES[@]}"; (( zc>0 )) || return 0
  for (( i=1; i<=count; i++ )); do
    local zone="${ZONES[$(((i-1)%zc))]}"; local name="${prefix}-${i}"
    ( create_vm "$p" "$name" "$zone" && echo OK || echo FAIL ) &
    running=$((running+1)); if (( running>=VM_PARALLEL )); then wait -n || true; running=$((running-1)); fi
  done
  while (( running>0 )); do wait -n || true; running=$((running-1)); done
  gcloud compute instances list --project "$p" \
    --filter="name~^${prefix}- AND tags.items=${TAG}" --format="value(name)" | wc -l
}

health_collect_lines(){
  local p="$1"
  gcloud compute instances list --project "$p" \
    --filter="status=RUNNING AND tags.items=${TAG}" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
  | while read -r ip; do
      [[ -n "$ip" ]] || continue
      if timeout 3 bash -lc "exec 3<>/dev/tcp/${ip}/${PROXY_PORT}" 2>/dev/null; then
        echo "${ip}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"
      fi
    done
}

# -------- Project & Billing (v3: luôn ưu tiên project mặc định, tạo thêm đúng 2 nếu cần) --------
billing_enabled(){
  gcloud beta billing projects describe "$1" --format="value(billingEnabled)" 2>/dev/null | grep -qx True
}

ensure_billing(){
  local p="$1"
  [[ -n "$BILLING_ACCOUNT" ]] || { say "Thiếu BILLING_ACCOUNT để gán billing cho $p"; exit 1; }
  if billing_enabled "$p"; then
    say "[$p] đã có billing -> bỏ qua link"
  else
    say "[$p] link billing -> $BILLING_ACCOUNT"
    gcloud beta billing projects link "$p" --billing-account="$BILLING_ACCOUNT" >/dev/null
  fi
}

create_project(){
  [[ -n "$BILLING_ACCOUNT" ]] || { say "Thiếu BILLING_ACCOUNT để tạo project mới."; exit 1; }
  local new_id="${PROJECT_PREFIX}-$(date +%y%m%d)-$RANDOM"
  local parent_args=()
  [[ -n "$FOLDER_ID" ]] && parent_args+=(--folder="$FOLDER_ID")
  [[ -z "$FOLDER_ID" && -n "$ORG_ID" ]] && parent_args+=(--organization="$ORG_ID")
  say "Tạo project: $new_id"
  gcloud projects create "$new_id" "${parent_args[@]}" >/dev/null
  echo "$new_id"
}

pick_three_projects(){
  # 1) Luôn lấy project mặc định nếu có (kể cả chưa gán billing)
  local defp; defp="$(default_project || true)"
  local -a chosen=()
  if [[ -n "$defp" ]]; then chosen+=("$defp"); fi

  # 2) Lấy thêm các project đã có billing (khác mặc định) cho đến khi đủ 3
  local p
  while read -r p; do
    [[ -n "$p" && "$p" != "$defp" ]] || continue
    chosen+=("$p")
    (( ${#chosen[@]} >= NEED_TOTAL )) && break
  done < <(gcloud projects list --format="value(projectId)" \
            | while read -r x; do
                gcloud beta billing projects describe "$x" --format="value(billingEnabled)" 2>/dev/null \
                  | grep -qx True && echo "$x"
              done)

  # 3) Nếu vẫn thiếu, tạo mới đúng số còn thiếu
  while (( ${#chosen[@]} < NEED_TOTAL )); do
    local newp; newp="$(create_project)"
    chosen+=("$newp")
  done

  printf "%s\n" "${chosen[@]}"
}

ensure_three_and_bill_all(){
  mapfile -t three < <(pick_three_projects)
  say "Danh sách 3 project: ${three[*]}"
  # Gán billing cho cả 3 (idempotent)
  for p in "${three[@]}"; do ensure_billing "$p"; done
  # trả về danh sách
  printf "%s\n" "${three[@]}"
}

deploy_one(){
  local p="$1"
  say "==== TRIỂN KHAI PROJECT: $p ===="
  enable_services "$p"
  ensure_firewall "$p"
  read -r tok_plan osa_plan < <(plan_counts "$p" "$TOKYO_WANT" "$OSAKA_WANT")
  say "[$p] plan theo quota: Tokyo=${tok_plan} | Osaka=${osa_plan}"

  local tok_created=0 osa_created=0
  (( tok_plan>0 )) && tok_created=$(create_many "$p" "proxy-tokyo" "$tok_plan" "${TOKYO_ZONES[@]}") || true
  (( osa_plan>0 )) && osa_created=$(create_many "$p" "proxy-osaka" "$osa_plan" "${OSAKA_ZONES[@]}") || true
  say "[$p] Đã tạo: Tokyo=${tok_created} | Osaka=${osa_created}"

  local lines; lines="$(health_collect_lines "$p" | sort -u)"
  [[ -n "$lines" ]] && { send_tg "$lines"; printf "%s\n" "$lines"; }
}

main(){
  need_bin gcloud; need_bin jq
  [[ "$NEED_TOTAL" -eq 3 ]] || say "Lưu ý: script đang tối ưu cho NEED_TOTAL=3."
  say "BẮT ĐẦU: lấy project mặc định + bổ sung để đủ 3, sau đó GÁN BILLING CHO CẢ 3."
  mapfile -t pick < <(ensure_three_and_bill_all)
  say "Triển khai cho: ${pick[*]}"

  pids=()
  for p in "${pick[@]}"; do ( deploy_one "$p" ) & pids+=($!); done

  ok=0 fail=0
  for pid in "${pids[@]}"; do if wait "$pid"; then ok=$((ok+1)); else fail=$((fail+1)); fi; done
  say "HOÀN TẤT. OK=${ok} FAIL=${fail}"
}

trap 'say "❌ Lỗi tại dòng $LINENO"; exit 1' ERR
main
# =================== end of regproxygg_v3.sh ===================
