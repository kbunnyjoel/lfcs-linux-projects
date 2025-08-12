#!/bin/bash
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

install_nginx() {
  info "Updating Homebrew…"; brew update >/dev/null
  if ! brew list nginx >/dev/null 2>&1; then
    info "Installing nginx…"; brew install nginx; ok "nginx installed."
  else
    ok "nginx already installed."
  fi
  mkdir -p "$WEBROOT" "$SERVERS_DIR"
}

deploy_site() {
  info "Deploying sample site to ${WEBROOT} …"
  ENV_UP="$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')"
  cat > "${WEBROOT}/index.html" <<HTML
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LFCS Project 1</title><link rel="stylesheet" href="style.css">
</head><body><main>
<h1>Welcome to LFCS Project 1 (${ENV_UP})!</h1>
<p>Your macOS nginx is up and serving content 🎉</p>
<p id="marker">${MARKER_TEXT}</p>
</main></body></html>
HTML

  cat > "${WEBROOT}/style.css" <<'CSS'
:root { font: 16px/1.45 -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; color: #222; }
body { margin: 0; background: #f8fafc; }
main { max-width: 720px; margin: 8vh auto; padding: 2rem; background: white; border-radius: 12px; box-shadow: 0 6px 24px rgba(0,0,0,.08); }
h1 { margin-top: 0; font-size: 2rem; }
p { margin: .5rem 0; }
CSS
  ok "Sample site deployed."
}

configure_port() {
  [[ -f "${NGINX_CONF}" ]] || fail "nginx.conf not found at ${NGINX_CONF}"
  if [[ ! -f "${NGINX_CONF}.bak" ]]; then
    cp "${NGINX_CONF}" "${NGINX_CONF}.bak"; info "Backed up nginx.conf → nginx.conf.bak"
  fi

  info "Setting 'listen ${PORT};' in ${NGINX_CONF} …"
  # Replace ONLY the first occurrence of: listen <number>;
  /usr/bin/awk -v port="${PORT}" '
    BEGIN { replaced=0 }
    {
      if (!replaced && $0 ~ /listen[[:space:]]+[0-9]+;/) {
        sub(/listen[[:space:]]+[0-9]+;/, "listen " port ";")
        replaced=1
      }
      print
    }
  ' "${NGINX_CONF}" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "${NGINX_CONF}"

  # Ensure servers/*.conf is included for extra vhosts (e.g., TLS server)
  if ! grep -Fq "include ${SERVERS_DIR}/*.conf;" "${NGINX_CONF}"; then
    info "Adding include for ${SERVERS_DIR}/*.conf into nginx.conf ..."
    /usr/bin/awk -v inc="    include ${SERVERS_DIR}/*.conf;" '
      !done && $0 ~ /^[[:space:]]*http[[:space:]]*\{[[:space:]]*$/ { print; print inc; done=1; next }
      { print }
    ' "${NGINX_CONF}" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "${NGINX_CONF}"
  fi
}

stop_nginx_if_running() {
  local need_sudo="false"
  if [[ "${PORT}" -lt 1024 || "${ENABLE_SSL}" == "true" ]]; then need_sudo="true"; fi
  local state; state="$(brew services list | awk '$1=="nginx"{print $2}' || true)"
  if [[ "${state}" == "started" ]]; then
    info "nginx is running; stopping it first…"
    if [[ "$need_sudo" == "true" ]]; then
      info "Using: sudo brew services stop nginx"
      sudo brew services stop nginx >/dev/null
    else
      info "Using: brew services stop nginx"
      brew services stop nginx >/dev/null
    fi
    ok "nginx stopped."
  else
    info "nginx is not running; nothing to stop."
  fi
}

start_nginx() {
  local need_sudo="false"
  if [[ "${PORT}" -lt 1024 || "${ENABLE_SSL}" == "true" ]]; then need_sudo="true"; fi
  info "Starting nginx via brew services…"
  local running; running="$(brew services list | awk '$1=="nginx"{print $2}' || true)"
  if [[ "${running}" == "started" ]]; then
    info "nginx running; restarting…"
    if [[ "$need_sudo" == "true" ]]; then
      info "Using: sudo brew services restart nginx"
      sudo brew services restart nginx >/dev/null
    else
      info "Using: brew services restart nginx"
      brew services restart nginx >/dev/null
    fi
  else
    if [[ "$need_sudo" == "true" ]]; then
      info "Using: sudo brew services start nginx"
      sudo brew services start nginx >/dev/null
    else
      info "Using: brew services start nginx"
      brew services start nginx >/dev/null
    fi
  fi
  ok "nginx service running."
}
