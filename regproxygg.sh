#!/bin/bash

# Script này chỉ có một nhiệm vụ: cài đặt proxy trên một project đã sẵn sàng.
# Nó không thực hiện bất kỳ thao tác nào liên quan đến billing hoặc project.

# Gán user và pass từ biến môi trường
PROXY_USER=${PROXY_USER:-"proxyuser"}
PROXY_PASS=${PROXY_PASS:-"proxypass"}

# Cài đặt các gói cần thiết
sudo apt-get update
sudo apt-get install -y dante-server

# Cấu hình Dante Server
cat <<EOF | sudo tee /etc/danted.conf
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

# Thêm người dùng proxy
sudo useradd -r -s /bin/false "$PROXY_USER"
echo -e "$PROXY_PASS\n$PROXY_PASS" | sudo passwd "$PROXY_USER"

# Khởi động lại dịch vụ Dante
sudo systemctl restart danted
sudo systemctl enable danted
