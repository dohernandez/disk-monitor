#!/usr/bin/env bash
# Runs INSIDE the test VM (as admin): create a self-signed "Disk Monitor Dev" code-signing
# identity in admin's login keychain, once per base image. Test builds signed with it keep a
# stable designated requirement, so the VM's Accessibility grant survives rebuilds.
# The private key never leaves the VM; the certificate is copied to ~/disk-monitor-dev-cert.pem.
# Usage: tart exec -i <vm> /bin/bash -s < guest-signing-cert.sh (golden.sh does this)
set -euo pipefail
NAME="Disk Monitor Dev"
K="$HOME/Library/Keychains/login.keychain-db"
security unlock-keychain -p admin "$K"
if security find-certificate -c "$NAME" "$K" >/dev/null 2>&1; then
    echo "exists: $NAME"; security find-identity -p codesigning "$K"; exit 0
fi
d=$(mktemp -d)
cat > "$d/cert.cnf" <<'C'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Disk Monitor Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
C
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/key.pem" -out "$d/cert.pem" -days 3650 -config "$d/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$d/key.pem" -in "$d/cert.pem" -out "$d/id.p12" -passout pass:dm
security import "$d/id.p12" -k "$K" -P dm -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k admin "$K" >/dev/null
# Not marked trusted: add-trusted-cert waits on a password dialog. codesign signs with the
# untrusted identity by SHA-1, and TCC matches the certificate leaf hash, not trust.
cp "$d/cert.pem" "$HOME/disk-monitor-dev-cert.pem"
rm -f "$d/key.pem" "$d/id.p12" "$d/cert.pem" "$d/cert.cnf"; rmdir "$d"
security find-identity -p codesigning "$K"
