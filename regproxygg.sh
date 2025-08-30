#!/bin/bash

# ==============================================================================
# SCRIPT CÀI ĐẶT PROXY DANTE TRÊN MỘT VM ĐƯỢC CHỈ ĐỊNH
# ==============================================================================

# Gán user và pass từ biến môi trường được truyền vào từ script chính
PROXY_USER=${PROXY_USER:-"proxyuser"}
PROXY_PASS=${PROXY_PASS:-"proxypass"}

# Cài đặt các gói cần thiết một cách không tương tác
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y dante-server

# Cấu hình Dante Server
# Sử dụng 'sudo tee' để ghi nội dung vào file cấu hình
sudo tee /etc/danted.conf > /dev/null <<EOF
logoutput: /var/log/dante.log
internal: eth0 port = 443
external: eth0

clientmethod: none
socksmethod: username none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
EOF

# Thêm người dùng proxy nếu chưa tồn tại
if ! id "$PROXY_USER" &>/dev/null; then
    sudo useradd -r -s /bin/false "$PROXY_USER"
fi

# Đặt mật khẩu cho người dùng
echo -e "$PROXY_PASS\n$PROXY_PASS" | sudo passwd "$PROXY_USER"

# Khởi động lại và bật dịch vụ Dante
# Lệnh này sẽ chạy thành công trên VM, nhưng sẽ báo lỗi trong Cloud Shell
# Tuy nhiên, điều này không ảnh hưởng đến việc cài đặt.
sudo systemctl restart danted
sudo systemctl enable danted
