#!/bin/bash

# ==============================================================================
# SCRIPT TẠO VÀ QUẢN LÝ PROXY GOOGLE CLOUD - PHIÊN BẢN TỐI ƯU
# ==============================================================================

# Cấu hình
PROJECT_PREFIX="proxygen"
NUM_PROJECTS=3
PROXY_SCRIPT_URL="https://raw.githubusercontent.com/quang273/dante-proxy-install/main/regproxygg.sh"
PROXY_USER="mr.quang"
PROXY_PASS="2703"
BOT_TOKEN="8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk"
USER_ID="6666449775"

# ==============================================================================
# Hàm hỗ trợ
# ==============================================================================

send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="$message"
}

# Hàm xử lý một project (liên kết billing và bật API)
process_project() {
    local PROJECT_ID=$1
    local BILLING_ACCOUNT=$2

    echo ">>> Xử lý project: $PROJECT_ID"
    send_telegram_message "⚙️ Đang xử lý project: $PROJECT_ID"

    # Kiểm tra liên kết billing
    local billing_info=$(gcloud beta billing projects describe "$PROJECT_ID" --format="value(billingEnabled)")
    if [[ "$billing_info" != "True" ]]; then
        echo "   - Liên kết billing..."
        gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" &> /dev/null
    else
        echo "   - Billing đã được liên kết. Bỏ qua."
    fi

    # Kiểm tra API Compute Engine
    local compute_api=$(gcloud services list --project="$PROJECT_ID" --filter="name:compute.googleapis.com" --format="value(STATE)")
    if [[ "$compute_api" != "ENABLED" ]]; then
        echo "   - Kích hoạt API Compute Engine..."
        gcloud services enable compute.googleapis.com --project="$PROJECT_ID" &> /dev/null
    else
        echo "   - API Compute Engine đã được kích hoạt. Bỏ qua."
    fi
    
    # Chạy script tạo proxy
    echo "   - Cài đặt proxy..."
    env PROXY_USER="$PROXY_USER" PROXY_PASS="$PROXY_PASS" \
    bash <(curl -fsSL "$PROXY_SCRIPT_URL") --project "$PROJECT_ID"
}

# ==============================================================================
# Quá trình thực thi
# ==============================================================================

echo ">>> Bắt đầu tạo và quản lý proxy Google Cloud - Phiên bản tối ưu"
send_telegram_message "🤖 Bắt đầu kiểm tra và tối ưu hóa các project..."

# Lấy tài khoản billing
BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" --limit=1)
if [ -z "$BILLING_ACCOUNT" ]; then
    echo "Lỗi: Không tìm thấy tài khoản thanh toán nào. Vui lòng kiểm tra lại."
    send_telegram_message "❌ Lỗi: Không tìm thấy tài khoản thanh toán nào. Vui lòng kiểm tra lại."
    exit 1
fi

# Đếm số project đã có
EXISTING_PROJECTS=$(gcloud projects list --filter="name~'proxygen-'" --format="value(projectId)")
EXISTING_COUNT=$(echo "$EXISTING_PROJECTS" | wc -w)
PROJECTS_TO_CREATE=$((NUM_PROJECTS - EXISTING_COUNT))

# Tạo project mới nếu chưa đủ
if (( PROJECTS_TO_CREATE > 0 )); then
    echo -e "\n--- Bước 1: Tạo $PROJECTS_TO_CREATE project mới ---"
    send_telegram_message "🔨 Đang tạo $PROJECTS_TO_CREATE project mới..."
    for i in $(seq 1 $PROJECTS_TO_CREATE); do
        PROJECT_ID="${PROJECT_PREFIX}-${RANDOM}"
        echo ">>> Tạo project: $PROJECT_ID"
        gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID" &> /dev/null
    done
else
    echo -e "\n--- Đã có đủ $NUM_PROJECTS project. Không cần tạo thêm. ---"
fi

# Lấy lại danh sách tất cả các project đã có và mới tạo
ALL_PROJECTS=$(gcloud projects list --filter="name~'proxygen-'" --format="value(projectId)")

# Xử lý tất cả các project song song
echo -e "\n--- Bước 2: Xử lý và cài đặt proxy cho tất cả project ---"
for PROJECT_ID in $ALL_PROJECTS; do
    process_project "$PROJECT_ID" "$BILLING_ACCOUNT" &
done

wait # Đợi tất cả các tiến trình con hoàn thành

# ==============================================================================
# Tổng hợp và Gửi Danh sách Proxy
# ==============================================================================

echo -e "\n--- Bước 3: Tổng hợp danh sách và gửi về Telegram ---"
send_telegram_message "📋 Đang tổng hợp danh sách proxy..."

PROXY_LIST=""

for PROJECT_ID in $ALL_PROJECTS; do
    IPS=$(gcloud compute instances list --project="$PROJECT_ID" \
        --filter="name~'^(proxy-sydney|proxy-melbourne)'" \
        --format="value(EXTERNAL_IP)")
    
    for IP in $IPS; do
        PROXY_ENTRY="${IP}:443:${PROXY_USER}:${PROXY_PASS}"
        PROXY_LIST+="$PROXY_ENTRY\n"
        echo "$PROXY_ENTRY"
    done
done

if [ -n "$PROXY_LIST" ]; then
    send_telegram_message "✅ Danh sách toàn bộ proxy đã sẵn sàng:\n$PROXY_LIST"
else
    send_telegram_message "❌ Không tìm thấy proxy nào được tạo. Vui lòng kiểm tra lại."
fi

echo -e "\n>>> Hoàn thành tất cả các bước."
