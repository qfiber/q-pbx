#!/bin/sh
# The lab's own certificate authority and a certificate for the test receiver on the backup
# VM (webhooks are HTTPS only, also in the lab). Kept in ~/.local/share/qpbx-lab/lab-ca,
# outside the repository; the lab inventory gives the server ca.pem to trust.
# usage: lab/tools/lab-ca.sh <receiver-ip>
set -eu
ip=$1
dir=$HOME/.local/share/qpbx-lab/lab-ca
mkdir -p "$dir" && chmod 700 "$dir" && cd "$dir"
if [ ! -f ca.pem ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=Q-PBX lab CA" -keyout ca.key -out ca.pem 2>/dev/null
fi
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$ip" \
  -keyout receiver.key -out receiver.csr 2>/dev/null
printf "subjectAltName=IP:%s\n" "$ip" > receiver.ext
openssl x509 -req -in receiver.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 825 \
  -extfile receiver.ext -out receiver.pem 2>/dev/null
chmod 600 ca.key receiver.key
echo "$dir"
