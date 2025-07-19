#!/bin/bash

REGIONS=("asia-northeast1" "asia-northeast2")

for region in "${REGIONS[@]}"; do
    for i in $(seq 1 4); do
        INSTANCE_NAME="proxy-$(echo $region | awk -F'-' '{print $3}')-$i"
        gcloud compute instances create "$INSTANCE_NAME" \
            --zone="${region}-a" \
            --machine-type=e2-micro \
            --image-family=debian-11 \
            --image-project=debian-cloud \
            --tags=socks5-proxy \
            --metadata=startup-script='#!/bin/bash
            apt update -y
            apt install -y dante-server
            cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: ens4 port=8888
external: ens4
method: username
user.notprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: connect disconnect error
}
EOF
useradd -m khoitran && echo "khoitran:khoi1" | chpasswd
systemctl restart danted
            ' \
            --network-tier=STANDARD \
            --boot-disk-size=10GB \
            --boot-disk-type=pd-balanced \
            --boot-disk-device-name="$INSTANCE_NAME"
    done
done
