#!/bin/bash

# --- Cores e Estilos ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' 
BOLD='\033[1m'

# --- Variáveis ---
INSTALL_DIR="/opt/dnscrypt-proxy"
CONFIG_URL="https://raw.githubusercontent.com/rgnldo/knot-resolver-suricata/master/dnscrypt-proxy.toml"
ADLIST_SCRIPT_URL="https://raw.githubusercontent.com/rgnldo/knot-resolver-suricata/master/gen_adlist.sh"

# --- Funções de Log ---
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✔]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✘]${NC} $1"; exit 1; }
log_process() { echo -ne "${CYAN}>>${NC} $1... "; }

# --- Verificações Iniciais ---
verificar_root() {
  [[ $EUID -ne 0 ]] && log_error "Execute como root (sudo)."
}

limpar_legados() {
  log_info "Limpando arquivos residuais do systemd..."
  rm -f /etc/systemd/system/dnscrypt-proxy-update-blocklists.service
  rm -f /etc/systemd/system/dnscrypt-proxy-update-blocklists.timer
  systemctl daemon-reload 2>/dev/null
}

# --- Criar Blocklists Básicas ---
criar_blocklists_basicas() {
  local blocklist="$INSTALL_DIR/blocked-names.txt"
  local allowlist="$INSTALL_DIR/allowed-names.txt"
  
  log_process "Criando blocklist básica"
  cat > "$blocklist" <<EOF
# Blocklist Básica - DNSCrypt-Proxy
# Gerada em: $(date)
# Formato: *.dominio.com (wildcard)

# Rastreadores conhecidos
*.doubleclick.net
*.googleadservices.com
*.google-analytics.com
*.facebook.com
*.analytics.google.com

# Malware/Phishing comuns
*.phishing-site.com
*.malware-domain.com

# Telemetria Windows
*.telemetry.microsoft.com
*.vortex.data.microsoft.com
EOF
  echo -e "${GREEN}OK${NC}"

  log_process "Criando allowlist básica"
  cat > "$allowlist" <<EOF
# Allowlist - Domínios Permitidos
# Estes domínios NUNCA serão bloqueados
# Formato: *.dominio.com

# Serviços essenciais
*.github.com
*.githubusercontent.com
*.cloudflare.com

# CDNs importantes
*.cloudfront.net
*.akamaihd.net

# Sistemas de pagamento
*.paypal.com
*.stripe.com
EOF
  echo -e "${GREEN}OK${NC}"
  
  chmod 644 "$blocklist" "$allowlist"
}

# --- Solução para Conflito com systemd-resolved ---
ajustar_resolved_stub() {
    local porta="$1"
    if [ "$porta" = "53" ]; then
        log_process "Liberando porta 53 no systemd-resolved"
        mkdir -p /etc/systemd/resolved.conf.d/
        cat <<EOF > /etc/systemd/resolved.conf.d/dnscrypt.conf
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
        echo -e "${GREEN}OK${NC}"
