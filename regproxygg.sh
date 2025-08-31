#!/bin/bash
# =====================================================================
# GCP SOCKS5 FARM v4.1 (Always reach 3 projects; prefer default project)
# - Ưu tiên project mặc định đã gán billing; nếu thiếu thì bổ sung project sẵn có
# - Nếu vẫn chưa đủ 3, tự tạo thêm project, link billing, bật API, cấp quyền
# - Mỗi project: 8 VM (4 Tokyo + 4 Osaka), SOCKS5 Dante (user/pass cố định)
# - Bỏ qua VM trùng tên; mọi thao tác idempotent (chạy lại vẫn an toàn)
# - Output: ip:port:user:pass
# =====================================================================

# KHÔNG set -e để tránh rớt shell vì 1 lỗi cục bộ
set -u

# ---------- CONFIG ----------
PREFIX="proxygen"                 # tiền tố khi PHẢI tạo project mới
NEED=3                            # cần đủ 3 project
TOKYO_ZONE="asia-northeast1-a"
OSAKA_ZONE="asia-northeast2-a"
PROXY_USER="mr.quang"
PROXY_PASS="2703"
PROXY_PORT="1080"
FIREWALL_NAME="allow-socks5-1080"

# Cho phép chỉ định Billing thủ công (tuỳ chọn):
: "${BILLING_ACCOUNT_ID:=}"       # ví dụ: BILLING_ACCOUNT_ID="000000-AAAAAA-BBBBBB"

say(){ echo -e "[ $(date '+%F %T') ] $*"; }
warn(){ echo -e "[WARN] $*" >&2; }
err(){ echo -e "[ERR ] $*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "Thiếu lệnh: $1"; exit 1; }; }

need gcloud; need awk; need sed; need grep; need tr

# ---------- Helpers ----------
active_acct(){ gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1; }
default_project(){ gcloud config get-value core/project 2>/dev/null | tr -d '\r'; }
project_has_billing(){
  local pid="$1"
  gcloud beta billing projects describe "$pid" --format="value(billingEnabled)" 2>/dev/null | grep -q "^True$"
}
project_billing_account(){
  local pid="$1"
  gcloud beta billing projects describe "$pid" --format="value(billingAccountName)" 2>/dev/null
}
pick_open_billing(){
  gcloud beta billing accounts list --filter="open=true" --format="value(name)" 2>/dev/null | head -n1
}

enable_apis(){
  local pid="$1"
  gcloud services enable serviceusage.googleapis.com --project="$pid" --quiet >/dev/null 2>&1 || true
  gcloud services enable compute.googleapis.com      --project="$pid" --quiet >/dev/null 2>&1 || true
  gcloud services enable iam.googleapis.com          --project="$pid" --quiet >/dev/null 2>&1 || true
}

grant_roles(){
  # yêu cầu bạn có quyền setIamPolicy; nếu không, lệnh này sẽ bị bỏ qua
  local pid="$1" who="user:$(active_acct)"
  [[ -z "$who" ]] && return 0
  gcloud projects add-iam-policy-binding "$pid" --member="$who" --role="roles/compute.admin" --quiet >/dev/null 2>&1 || true
  gcloud projects add-iam-policy-binding "$pid" --member="$who" --role="roles/iam.serviceAccountUser" --quiet >/dev/null 2>&1 || true
  gcloud projects add-iam-policy-binding "$pid" --member="$who" --role="roles/serviceusage.serviceUsageAdmin" --quiet >/dev/null 2>&1 || true
}

prepare_existing_project(){
  # Thử “chuẩn hoá” project có sẵn: bật API & cấp quyền cơ bản (nếu có quyền)
  local pid="$1"
  project_has_billing "$pid" || return 1
  enable_apis "$pid" || true
  grant_roles "$pid" || true
  return 0
}

check_project_ready(){
  local pid="$1"
  gcloud projects describe "$pid" --format="value(projectId)" --quiet >/dev/null 2>&1 || return 1
  project_has_billing "$pid" || return 1
  gcloud services list --enabled --project="$pid" \
    --filter="NAME=compute.googleapis.com" --format="value(NAME)" --quiet | grep -q "compute.googleapis.com" || return 1
  gcloud compute instances list --project="$pid" --limit=1 --quiet >/dev/null 2>&1 || return 1
  return 0
}

ensure_firewall(){
  local pid="$1"
  gcloud compute firewall-rules describe "$FIREWALL_NAME" --project="$pid" --quiet >/dev/null 2>&1 && return 0
  gcloud compute firewall-rules create "$FIREWALL_NAME" \
    --project="$pid" --allow="tcp:${PROXY_PORT}" \
    --direction=INGRESS --priority=1000 --network=default \
    --target-tags="socks5" --quiet >/dev/null 2>&1 || warn "[$pid] tạo firewall lỗi (bỏ qua)."
}

# ---------- Startup script (Dante) ----------
SS_FILE="/tmp/startup_socks5.sh"
cat >"$SS_FILE" <<'EOS'
#!/bin/bash
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y dante-server curl || apt-get install -y dante-server || true

# user/pass
id -u mr.quang &>/dev/null || useradd -m -s /usr/sbin/nologin mr.quang || true
echo "mr.quang:2703" | chpasswd || true

# iface
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)"
[[ -z "$IFACE" ]] && IFACE="eth0"

# danted.conf
cat >/etc/danted.conf <<EOC
logoutput: syslog
internal: $IFACE port = 1080
external: $IFACE
method: username
user.notprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect error }
pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  method: username
  log: connect disconnect error
}
EOC

systemctl enable danted || true
systemctl restart danted || systemctl start danted || true
iptables -I INPUT -p tcp --dport 1080 -j ACCEPT 2>/dev/null || true

EXT_IP="$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
echo "${EXT_IP}:1080:mr.quang:2703" >/root/_proxy.txt 2>/dev/null || true
EOS
chmod +x "$SS_FILE" || true

# ---------- Create projects if needed ----------
create_projects_to_reach_three(){
  local target_bill="$1"; local need_more="$2"
  local created=()
  [[ "$need_more" -le 0 ]] && { echo ""; return 0; }

  for i in $(seq 1 "$need_more"); do
    local pid="${PREFIX}-$(date +%s)$RANDOM"
    say "[create $i/$need_more] tạo project: $pid"
    gcloud projects create "$pid" --name="$pid" --quiet >/dev/null || { err "Tạo project lỗi: $pid"; exit 1; }
    say "[create] link billing: $target_bill"
    gcloud beta billing projects link "$pid" --billing-account="$target_bill" --quiet >/dev/null || { err "Link billing lỗi: $pid"; exit 1; }
    say "[create] bật API"
    enable_apis "$pid"
    say "[create] cấp quyền cho $(active_acct)"
    grant_roles "$pid"
    created+=("$pid")
  done
  echo "${created[*]}"
}

# ---------- Create VM (idempotent) ----------
create_vm(){
  local pid="$1" name="$2" zone="$3"
  # skip nếu đã có
  gcloud compute instances describe "$name" --zone="$zone" --project="$pid" --quiet >/dev/null 2>&1 && {
    say "[$pid] $name đã tồn tại → skip"; return 0; }

  gcloud compute instances create "$name" \
    --project="$pid" --zone="$zone" --machine-type="e2-micro" \
    --image-family="ubuntu-2204-lts" --image-project="ubuntu-os-cloud" \
    --boot-disk-size="10GB" --boot-disk-type="pd-balanced" \
    --tags="socks5" \
    --metadata=enable-oslogin=true \
    --metadata-from-file=startup-script="$SS_FILE" \
    --quiet >/dev/null 2>&1 || { warn "[$pid] tạo VM lỗi: $name"; return 1; }
}

# ---------- Batch per Project ----------
batch_project(){
  local pid="$1" lg="/tmp/${pid}.log"
  {
    say "[$pid] chuẩn hoá quyền & API…"
    prepare_existing_project "$pid" || true

    say "[$pid] kiểm tra điều kiện…"
    if ! check_project_ready "$pid"; then
      err "[$pid] chưa sẵn sàng (billing/API/quyền). Bỏ qua."; exit 1; fi

    say "[$pid] firewall…"; ensure_firewall "$pid"

    say "[$pid] tạo 4 Tokyo + 4 Osaka…"
    create_vm "$pid" "proxy-tokyo-1" "$TOKYO_ZONE" &
    create_vm "$pid" "proxy-tokyo-2" "$TOKYO_ZONE" &
    create_vm "$pid" "proxy-tokyo-3" "$TOKYO_ZONE" &
    create_vm "$pid" "proxy-tokyo-4" "$TOKYO_ZONE" &
    create_vm "$pid" "proxy-osaka-1" "$OSAKA_ZONE" &
    create_vm "$pid" "proxy-osaka-2" "$OSAKA_ZONE" &
    create_vm "$pid" "proxy-osaka-3" "$OSAKA_ZONE" &
    create_vm "$pid" "proxy-osaka-4" "$OSAKA_ZONE" &
    wait

    say "[$pid] chờ IP (40s)…"; sleep 40

    say "[$pid] PROXY:"
    gcloud compute instances list \
      --project="$pid" \
      --filter="name~'^proxy-(tokyo|osaka)'" \
      --format="get(networkInterfaces[0].accessConfigs[0].natIP)" \
      --quiet \
      | sed '/^$/d' | awk -v p="${PROXY_PORT}" -v u="${PROXY_USER}" -v s="${PROXY_PASS}" '{print $1":"p":"u":"s}'
  } >"$lg" 2>&1
}

# ================= MAIN =================
say "Active account: $(active_acct || echo none)"
DEF="$(default_project || true)"

# (A) Lập danh sách candidate: mặc định trước, rồi ưu tiên prefix, rồi phần còn lại
CAND=()
if [[ -n "$DEF" ]]; then CAND+=("$DEF"); fi
ALL="$(gcloud projects list --format='value(projectId)' 2>/dev/null)"
PRIORITY=(); OTHERS=()
while read -r p; do
  [[ -z "$p" ]] && continue
  [[ "$p" == "$DEF" ]] && continue
  if [[ "$p" == ${PREFIX}-* ]]; then PRIORITY+=("$p"); else OTHERS+=("$p"); fi
done <<< "$ALL"
CAND+=("${PRIORITY[@]}" "${OTHERS[@]}")

# (B) Thử chuẩn hoá và chọn đủ 3 project sẵn có
PICK=()
for pid in "${CAND[@]}"; do
  prepare_existing_project "$pid" || true
  check_project_ready "$pid" || continue
  PICK+=("$pid")
  [[ ${#PICK[@]} -ge $NEED ]] && break
done

# (C) Nếu thiếu → tạo thêm cho đủ 3, tái dùng billing của project mặc định / biến env / hoặc auto pick OPEN
if [[ ${#PICK[@]} -lt $NEED ]]; then
  BILL_ACCT=""
  # Ưu tiên biến môi trường nếu người dùng set
  if [[ -n "${BILLING_ACCOUNT_ID:-}" ]]; then
    BILL_ACCT="$BILLING_ACCOUNT_ID"
  else
    # Thử lấy theo project mặc định
    if [[ -n "$DEF" && "$(project_has_billing "$DEF" && echo yes || echo no)" == "yes" ]]; then
      BILL_ACCT="$(project_billing_account "$DEF")"
    fi
    # Nếu vẫn trống → auto pick OPEN
    [[ -z "$BILL_ACCT" ]] && BILL_ACCT="$(pick_open_billing)"
  fi

  [[ -n "$BILL_ACCT" ]] || { err "Không tìm thấy Billing Account. Hãy set BILLING_ACCOUNT_ID hoặc bật billing cho project mặc định."; exit 1; }

  NEED_MORE=$(( NEED - ${#PICK[@]} ))
  say "Đang tạo thêm $NEED_MORE project (billing: $BILL_ACCT) cho đủ $NEED…"
  read -r -a CREATED <<<"$(create_projects_to_reach_three "$BILL_ACCT" "$NEED_MORE")"
  PICK+=("${CREATED[@]}")
fi

say "Dùng 3 project: ${PICK[*]}"

# (D) Tạo proxy song song; mỗi project log riêng
for pid in "${PICK[@]}"; do batch_project "$pid" & done
wait

say "=== TỔNG HỢP PROXY (ip:port:user:pass) ==="
for pid in "${PICK[@]}"; do
  echo "# $pid"
  if [[ -s "/tmp/${pid}.log" ]]; then
    # Trích phần sau 'PROXY:' trong log
    awk '/PROXY:/{flag=1;next} /chờ IP|Chờ IP|^\[/{next} flag && NF' "/tmp/${pid}.log" \
      | sed '/^\[/d' | sed '/^$/d'
  else
    warn "[$pid] Không có log."
  fi
done

say "Xem log: /tmp/<projectId>.log"
