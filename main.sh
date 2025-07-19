#!/bin/bash
set -euo pipefail

NUM_TARGET=3
PROJECT_PREFIX=proxygen
REG_SCRIPT_URL="https://raw.githubusercontent.com/quang273/dante-proxy-install/main/regproxygg.sh"
BOT_TOKEN="7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM"
USER_ID="1053423800"
created=()
attempts=0

while (( ${#created[@]} < NUM_TARGET && attempts < 10 )); do
  ((attempts++))
  PROJECT_ID="${PROJECT_PREFIX}-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
  echo "📌 Thử tạo: $PROJECT_ID"

  if gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"; then
    echo "✅ Tạo thành công: $PROJECT_ID"

    echo "🔗 Gắn billing..."
    gcloud beta billing projects link "$PROJECT_ID" \
      --billing-account=01A547-68AF0C-91B8BC || continue

    echo "🚀 Kích hoạt các API..."
    gcloud services enable compute.googleapis.com iam.googleapis.com \
      cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
      --project="$PROJECT_ID" || continue

    echo "⚙️ Chạy regproxygg.sh trên $PROJECT_ID"
    export PROJECT_ID="$PROJECT_ID"
    curl -sSL "$REG_SCRIPT_URL" | bash
    created+=("$PROJECT_ID")
  else
    echo "❌ Không tạo được $PROJECT_ID"
  fi
done

echo "🎉 Đã tạo ${#created[@]} project:"
printf '%s\n' "${created[@]}"
