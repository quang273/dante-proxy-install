#!/bin/bash
set -euo pipefail

# CONFIG
NUM_TARGET=3
PROJECT_PREFIX="proxygen"
REG_SCRIPT_URL="https://raw.githubusercontent.com/quang273/dante-proxy-install/main/regproxygg.sh"

BOT_TOKEN="7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM"
USER_ID="1053423800"

send_to_telegram(){
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$USER_ID" -d text="$1" > /dev/null
}

created=()
attempts=0

while (( ${#created[@]} < NUM_TARGET )); do
  ((attempts++))
  PROJECT_ID="${PROJECT_PREFIX}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
  echo "➡️ Thử tạo project ($attempts): $PROJECT_ID"
  if gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID" &>/dev/null; then
    BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | head -n1)
    gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

    echo "🔄 Đang bật API cho project: $PROJECT_ID"
    gcloud services enable compute.googleapis.com \
                             iam.googleapis.com \
                             cloudresourcemanager.googleapis.com \
                             serviceusage.googleapis.com \
                             --project="$PROJECT_ID"
    echo "✅ Đã bật đủ API cho: $PROJECT_ID"

    created+=("$PROJECT_ID")
    echo "✅ Tạo thành công: $PROJECT_ID"
  else
    echo "❌ Tạo thất bại: $PROJECT_ID - tiếp tục..."
  fi

  if (( attempts > NUM_TARGET*3 )); then
    send_to_telegram "⚠️ Không tạo đủ $NUM_TARGET project sau $attempts lần – có thể hết quota"
    break
  fi
done

if (( ${#created[@]} == 0 )); then
  send_to_telegram "🚫 Không tạo được project nào – dừng xử lý."
  exit 1
fi

send_to_telegram "✅ Đã tạo ${#created[@]} project: ${created[*]}"

for prj in "${created[@]}"; do
  (
    gcloud config set project "$prj"
    curl -s "$REG_SCRIPT_URL" -o regproxygg.sh
    chmod +x regproxygg.sh
    PROJECT_ID="$prj" bash regproxygg.sh
  ) &
  sleep 2
done

wait

send_to_telegram "🎯 Hoàn tất xử lý ${#created[@]} project."
