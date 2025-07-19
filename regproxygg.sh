#!/bin/bash
set -euo pipefail

# Cấu hình người dùng và Telegram
REGIONS=("asia-northeast1" "asia-northeast2")
USERNAME="khoitran"
PASSWORD="khoi1"
PORT=8888

BOT_TOKEN="7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM"
USER_ID="1053423800"
PROJECT_ID=${PROJECT_ID:-$(gcloud config get-value project)}

send_to_telegram(){
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$USER_ID" -d text="$1" > /dev/null
}

mkdir -p proxies
ALL_PROXY=""

# ✅ Tạo proxy đa luồng
for region in "${REGIONS[@]}"; do
  for i in $(seq 1 4); do
    INSTANCE_NAME="proxy-$(echo $region | awk -F'-' '{print $3}')-$i"

    gcloud compute instances create "$INSTANCE_NAME" \
      --zone="${region}-a" \
      --machine-type=e2-micro \
      --image-family=debian-11 \
      --image-project=debian-cloud \
      --tags=socks5-proxy \
      --metadata=startup-script="#!/bin/bash
        apt update -y
        apt install -y dante-server
        cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: ens4 port=$PORT
external: ens4
method: username
user.notprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log:connect disconnect error }
pass { from: 0.0.0.0/0 to: 0.0.0.0/0 protocol:tcp udp log:connect disconnect error }
EOF
        useradd -m $USERNAME && echo \"$USERNAME:$PASSWORD\" | chpasswd
        systemctl restart danted" \
      --network-tier=STANDARD \
      --boot-disk-size=10GB \
      --boot-disk-type=pd-balanced &  # ✅ CHẠY NỀN (đa luồng)
    
    sleep 0.5  # giảm tải API gọi liên tục
  done
done

wait  # ✅ Đợi tất cả VM tạo xong

sleep 15  # chờ VM khởi động

# ✅ Lấy IP các VM và gửi về Telegram
for region in "${REGIONS[@]}"; do
  for i in $(seq 1 4); do
    INSTANCE_NAME="proxy-$(echo $region | awk -F'-' '{print $3}')-$i"
    IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
         --zone="${region}-a" --project="$PROJECT_ID" \
         --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    
    if [[ -n "$IP" ]]; then
      LINE="$IP:$PORT:$USERNAME:$PASSWORD"
      echo "$LINE" | tee -a proxies/all_proxy.txt
      ALL_PROXY+="$LINE"$'\n'
    fi
  done
done

send_to_telegram "$ALL_PROXY"
