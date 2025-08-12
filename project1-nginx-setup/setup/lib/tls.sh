#!/bin/bash
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ensure_tls() {
  [[ "${ENABLE_SSL}" == "true" ]] || { rm -f "${SERVERS_DIR}/lfcs-ssl.conf" || true; return; }

  mkdir -p "${CERT_DIR}"
  local CERT="${CERT_DIR}/lfcs.crt"
  local KEY="${CERT_DIR}/lfcs.key"

  if [[ ! -s "${CERT}" || ! -s "${KEY}" ]]; then
    info "Generating self-signed TLS cert (CN=${SERVER_NAME})…"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -subj "/CN=${SERVER_NAME}" \
      -keyout "${KEY}" -out "${CERT}" >/dev/null 2>&1
    ok "Self-signed cert created."
  else
    info "Existing TLS cert found, skipping generation."
    ok "Existing TLS cert verified."
  fi

  local SSL_CONF="${SERVERS_DIR}/lfcs-ssl.conf"
  cat > "${SSL_CONF}" <<EOF
# Added by setup/lib/tls.sh
server {
    listen 443 ssl;
    server_name ${SERVER_NAME};
    root ${WEBROOT};

    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / { try_files \$uri \$uri/ =404; }
}
EOF
  ok "HTTPS server config written: ${SSL_CONF}"

  # Ensure servers/*.conf is included (use NGINX_CONF from common.sh)
  if ! grep -qE "include[[:space:]]+${SERVERS_DIR}/\\*\\.conf;" "${NGINX_CONF}"; then
    info "Adding include directive for server configs to nginx.conf"
    /usr/bin/awk -v inc="    include ${SERVERS_DIR}/*.conf;" '
      !done && $0 ~ /^[[:space:]]*http[[:space:]]*\{[[:space:]]*$/ { print; print inc; done=1; next }
      { print }
    ' "${NGINX_CONF}" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "${NGINX_CONF}"
    ok "Include directive added to nginx.conf"
  else
    info "Include directive for server configs already present in nginx.conf"
  fi

  # Note: do not restart here; install.sh handles start/restart sequencing.
}
