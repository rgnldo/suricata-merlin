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
    fi
}

# --- Configurar Agendamento Automático (OTIMIZADO PARA NOTEBOOK) ---
configurar_agendamento() {
  log_process "Configurando atualização automática inteligente"
  
  # Criar timer systemd (otimizado para notebooks com suspensão)
  cat > /etc/systemd/system/dnscrypt-blocklist.timer <<'EOF'
[Unit]
Description=Atualização Inteligente de Blocklists DNSCrypt
Requires=dnscrypt-blocklist.service

[Timer]
# Executa 24h após a última execução bem-sucedida
# ✅ Funciona mesmo com suspensões frequentes
OnUnitActiveSec=24h

# Executa 5min após boot/reinício
OnBootSec=5min

# Delay aleatório para evitar picos de tráfego
RandomizedDelaySec=30min

# Recupera execuções perdidas (se desligado/suspenso)
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Criar service systemd
  cat > /etc/systemd/system/dnscrypt-blocklist.service <<EOF
[Unit]
Description=Atualizar Blocklists DNSCrypt
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/gen_adlist.sh
ExecStartPost=/bin/systemctl reload dnscrypt-proxy
WorkingDirectory=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal

# Timeout de 10min (blocklists grandes podem demorar)
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dnscrypt-blocklist.timer
  systemctl start dnscrypt-blocklist.timer
  echo -e "${GREEN}OK${NC}"
  
  log_success "Agendamento configurado para notebooks"
  log_info "Atualiza: 24h após última execução (funciona com suspensão)"
}

# --- Configurar NetworkManager Dispatcher (ALTERNATIVA) ---
configurar_network_dispatcher() {
  log_process "Configurando atualização ao conectar WiFi/Ethernet"
  
  mkdir -p /etc/NetworkManager/dispatcher.d/
  cat > /etc/NetworkManager/dispatcher.d/50-update-dnscrypt-blocklist <<'EOF'
#!/bin/sh
# Atualiza blocklists ao conectar rede (máximo 1x a cada 24h)

STAMP_FILE="/var/run/dnscrypt-blocklist-last-update"

# Só executa ao conectar (não ao desconectar)
if [ "$2" = "up" ]; then
    # Verifica se já rodou nas últimas 24h (1440 minutos)
    if [ ! -f "$STAMP_FILE" ] || [ "$(find "$STAMP_FILE" -mmin +1440 2>/dev/null)" ]; then
        # Aguarda 2min para estabilizar conexão
        sleep 120
        
        # Executa atualização
        systemctl start dnscrypt-blocklist.service
        
        # Marca timestamp
        touch "$STAMP_FILE"
        
        logger "dnscrypt-blocklist: Atualização iniciada via NetworkManager"
    fi
fi
EOF

  chmod +x /etc/NetworkManager/dispatcher.d/50-update-dnscrypt-blocklist
  
  # Ainda precisa do service (mas não do timer)
  cat > /etc/systemd/system/dnscrypt-blocklist.service <<EOF
[Unit]
Description=Atualizar Blocklists DNSCrypt
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/gen_adlist.sh
ExecStartPost=/bin/systemctl reload dnscrypt-proxy
WorkingDirectory=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dnscrypt-blocklist.service
  echo -e "${GREEN}OK${NC}"
  
  log_success "NetworkManager dispatcher configurado"
  log_info "Atualiza ao conectar WiFi/Ethernet (máximo 1x/dia)"
}

# --- Desativar Agendamento ---
desativar_agendamento() {
  log_process "Removendo agendamento automático"
  systemctl stop dnscrypt-blocklist.timer 2>/dev/null
  systemctl disable dnscrypt-blocklist.timer 2>/dev/null
  systemctl disable dnscrypt-blocklist.service 2>/dev/null
  rm -f /etc/systemd/system/dnscrypt-blocklist.{timer,service}
  rm -f /etc/NetworkManager/dispatcher.d/50-update-dnscrypt-blocklist
  rm -f /var/run/dnscrypt-blocklist-last-update
  systemctl daemon-reload
  echo -e "${GREEN}OK${NC}"
}

# --- Ativar/Desativar Blocklists no Config ---
ativar_blocklists_config() {
  log_process "Ativando blocklists no dnscrypt-proxy.toml"
  sed -i "s|^# *blocked_names_file.*|blocked_names_file = 'blocked-names.txt'|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  sed -i "s|^# *allowed_names_file.*|allowed_names_file = 'allowed-names.txt'|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  echo -e "${GREEN}OK${NC}"
}

desativar_blocklists_config() {
  log_process "Desativando blocklists no dnscrypt-proxy.toml"
  sed -i "s|^blocked_names_file.*|# blocked_names_file = 'blocked-names.txt'|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  sed -i "s|^allowed_names_file.*|# allowed_names_file = 'allowed-names.txt'|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  echo -e "${GREEN}OK${NC}"
}

# --- Opção 1: Instalação / Atualização (SEM BLOCKLISTS) ---
instalar_binario() {
  echo -e "\n${BOLD}--- INSTALAÇÃO / ATUALIZAÇÃO ---${NC}"
  limpar_legados
  
  # Detecção de Arquitetura
  arch=$(uname -m | sed 's/x86_64/x86_64/;s/aarch64/arm64/;s/armv7.*/arm/')
  
  log_process "Buscando versão no GitHub"
  URL=$(curl -s https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | \
        jq -r ".assets[] | select(.name | contains(\"linux_$arch\")) | .browser_download_url" | head -n 1)
  echo -e "${GREEN}OK${NC}"

  log_process "Baixando e extraindo binário"
  mkdir -p "$INSTALL_DIR"
  curl -sL "$URL" -o /tmp/dnscrypt.tar.gz
  tar xzf /tmp/dnscrypt.tar.gz -C "$INSTALL_DIR" --strip-components=1
  echo -e "${GREEN}OK${NC}"

  # Interação
  echo -e "\n${YELLOW}Configurações Personalizadas:${NC}"
  read -p "  1. IP para escuta [Padrão 127.0.0.2]: " NOVO_IP
  NOVO_IP=${NOVO_IP:-127.0.0.2}
  read -p "  2. Porta para escuta [Padrão 53]: " NOVA_PORTA
  NOVA_PORTA=${NOVA_PORTA:-53}
  read -p "  3. Habilitar Cache DNS? (S/n): " CACHE_OPT
  [[ "$CACHE_OPT" =~ ^[Nn]$ ]] && CACHE_VAL="false" || CACHE_VAL="true"

  # Solução de Conflitos e IP
  ajustar_resolved_stub "$NOVA_PORTA"
  log_process "Configurando IP no Loopback"
  ip addr add "$NOVO_IP"/32 dev lo 2>/dev/null
  echo -e "${GREEN}OK${NC}"

  log_process "Aplicando permissões de porta (Capabilities)"
  chmod +x "$INSTALL_DIR/dnscrypt-proxy"
  setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/dnscrypt-proxy"
  echo -e "${GREEN}OK${NC}"

  log_process "Configurando dnscrypt-proxy.toml"
  [ ! -f "$INSTALL_DIR/dnscrypt-proxy.toml" ] && curl -sL "$CONFIG_URL" -o "$INSTALL_DIR/dnscrypt-proxy.toml"
  sed -i "s|^listen_addresses.*|listen_addresses = ['$NOVO_IP:$NOVA_PORTA']|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  sed -i "s|^cache =.*|cache = $CACHE_VAL|" "$INSTALL_DIR/dnscrypt-proxy.toml"
  echo -e "${GREEN}OK${NC}"

  log_process "Registrando serviço com bypass de AppArmor"
  cd "$INSTALL_DIR"
  ./dnscrypt-proxy -service uninstall 2>/dev/null
  ./dnscrypt-proxy -service install >/dev/null
  
  # Edição do serviço
  SERVICE_FILE="/etc/systemd/system/dnscrypt-proxy.service"
  if [ -f "$SERVICE_FILE" ]; then
    sed -i '/\[Service\]/a AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\nAppArmorProfile=unconfined' "$SERVICE_FILE"
  fi
  
  systemctl daemon-reload
  systemctl restart dnscrypt-proxy
  echo -e "${GREEN}OK${NC}"

  log_success "DNSCrypt-proxy instalado em $NOVO_IP:$NOVA_PORTA"
  log_info "Use a Opção 2 para configurar Blocklists"
}

# --- Opção 2: Gerenciar Blocklists (COMPLETO) ---
gerenciar_blocklist() {
  echo -e "\n${BOLD}--- GERENCIAR BLOCKLISTS ---${NC}"
  [ ! -d "$INSTALL_DIR" ] && log_error "Instale primeiro o DNSCrypt (Opção 1)."
  
  echo -e "${CYAN}1)${NC} Instalar e Configurar Blocklists"
  echo -e "   (Cria listas básicas + baixa listas avançadas)"
  echo ""
  echo -e "${CYAN}2)${NC} Atualizar listas agora (manual)"
  echo -e "${CYAN}3)${NC} Configurar atualização automática"
  echo -e "   ${YELLOW}a)${NC} Timer inteligente (notebook com suspensão)"
  echo -e "   ${YELLOW}b)${NC} NetworkManager (ao conectar WiFi)"
  echo -e "${CYAN}4)${NC} Desativar atualização automática"
  echo -e "${CYAN}5)${NC} Ver status do agendamento"
  echo ""
  echo -e "${CYAN}6)${NC} Desinstalar Blocklists"
  echo -e "${CYAN}7)${NC} Voltar"
  read -p "Selecione: " opt
  
  case $opt in
    1) 
      echo -e "\n${BOLD}=== INSTALAÇÃO DE BLOCKLISTS ===${NC}"
      
      # Criar listas básicas
      criar_blocklists_basicas
      
      # Ativar no config
      ativar_blocklists_config
      
      # Oferecer listas avançadas
      echo ""
      log_info "Deseja baixar listas avançadas do GitHub? (Recomendado)"
      read -p "Baixar gen_adlist.sh e executar? (S/n): " ADLIST_OPT
      
      if [[ ! "$ADLIST_OPT" =~ ^[Nn]$ ]]; then
        log_process "Baixando gen_adlist.sh"
        curl -sL "$ADLIST_SCRIPT_URL" -o "$INSTALL_DIR/gen_adlist.sh"
        chmod +x "$INSTALL_DIR/gen_adlist.sh"
        echo -e "${GREEN}OK${NC}"
        
        log_info "Compilando listas avançadas (pode demorar)..."
        cd "$INSTALL_DIR" && ./gen_adlist.sh
        
        # Oferecer agendamento com opções para notebook
        echo ""
        echo -e "${YELLOW}Escolha o tipo de atualização automática:${NC}"
        echo -e "  ${CYAN}a)${NC} Timer inteligente (recomendado para notebooks)"
        echo -e "      - Atualiza 24h após última execução"
        echo -e "      - Funciona com suspensão/hibernação"
        echo ""
        echo -e "  ${CYAN}b)${NC} NetworkManager dispatcher"
        echo -e "      - Atualiza ao conectar WiFi/Ethernet"
        echo -e "      - Ideal para conexões intermitentes"
        echo ""
        echo -e "  ${CYAN}n)${NC} Não agendar (atualização manual)"
        echo ""
        read -p "Escolha (a/b/n): " SCHEDULE_OPT
        
        case "$SCHEDULE_OPT" in
          a|A) configurar_agendamento ;;
          b|B) configurar_network_dispatcher ;;
          *) log_info "Atualização automática não configurada" ;;
        esac
      fi
      
      systemctl restart dnscrypt-proxy
      log_success "Blocklists instaladas e ativadas!"
      ;;
      
    2) 
      if [ ! -f "$INSTALL_DIR/gen_adlist.sh" ]; then
        log_process "Baixando gen_adlist.sh"
        curl -sL "$ADLIST_SCRIPT_URL" -o "$INSTALL_DIR/gen_adlist.sh"
        chmod +x "$INSTALL_DIR/gen_adlist.sh"
        echo -e "${GREEN}OK${NC}"
      fi
      
      log_info "Atualizando listas..."
      cd "$INSTALL_DIR" && ./gen_adlist.sh
      systemctl restart dnscrypt-proxy
      log_success "Listas atualizadas!"
      ;;
      
    3)
      echo -e "\n${YELLOW}Escolha o método de atualização:${NC}"
      echo -e "  ${CYAN}a)${NC} Timer inteligente (notebook/suspensão)"
      echo -e "  ${CYAN}b)${NC} NetworkManager (ao conectar rede)"
      read -p "Escolha (a/b): " method
      
      case "$method" in
        a|A) configurar_agendamento ;;
        b|B) configurar_network_dispatcher ;;
        *) log_warn "Opção inválida" ;;
      esac
      ;;
    
    4) desativar_agendamento ;;
    
    5) 
      echo -e "\n${BOLD}═══ Status do Agendamento ═══${NC}"
      
      # Verifica timer
      if systemctl is-active --quiet dnscrypt-blocklist.timer; then
        echo -e "\n${GREEN}✓ Timer Systemd ATIVO${NC}"
        systemctl status dnscrypt-blocklist.timer --no-pager -l
        echo -e "\n${BOLD}Próxima execução:${NC}"
        systemctl list-timers dnscrypt-blocklist.timer --no-pager
      else
        echo -e "\n${YELLOW}⊘ Timer não ativo${NC}"
      fi
      
      # Verifica dispatcher
      if [ -f /etc/NetworkManager/dispatcher.d/50-update-dnscrypt-blocklist ]; then
        echo -e "\n${GREEN}✓ NetworkManager Dispatcher CONFIGURADO${NC}"
        if [ -f /var/run/dnscrypt-blocklist-last-update ]; then
          last_update=$(stat -c %y /var/run/dnscrypt-blocklist-last-update | cut -d. -f1)
          echo -e "  Última atualização: $last_update"
        else
          echo -e "  ${YELLOW}Ainda não executou${NC}"
        fi
      fi
      
      # Histórico de execuções
      echo -e "\n${BOLD}Últimas 5 execuções:${NC}"
      journalctl -u dnscrypt-blocklist.service -n 5 --no-pager -o short-iso
      ;;
      
    6)
      log_warn "Isso irá desativar e remover as blocklists"
      read -p "Confirmar? (s/N): " resp
      if [[ "$resp" =~ ^[Ss]$ ]]; then
        desativar_agendamento
        desativar_blocklists_config
        rm -f "$INSTALL_DIR/blocked-names.txt" "$INSTALL_DIR/allowed-names.txt" "$INSTALL_DIR/gen_adlist.sh"
        systemctl restart dnscrypt-proxy
        log_success "Blocklists removidas!"
      fi
      ;;
      
    7) return ;;
  esac
}

# --- Sistema DNS ---
configurar_dns_global() {
  log_warn "Isso desativará o resolv do sistema!"
  read -p "Confirmar? (s/N): " resp
  if [[ "$resp" =~ ^[Ss]$ ]]; then
    systemctl disable --now systemd-resolved 2>/dev/null
    chattr -i /etc/resolv.conf 2>/dev/null
    rm -f /etc/resolv.conf
    IP_CONF=$(grep "listen_addresses =" "$INSTALL_DIR/dnscrypt-proxy.toml" | head -n 1 | cut -d"'" -f2 | cut -d":" -f1)
    echo "nameserver ${IP_CONF:-127.0.0.2}" > /etc/resolv.conf
    log_success "Agora usando DNSCrypt como DNS Global."
  fi
}

restaurar_original() {
  chattr -i /etc/resolv.conf 2>/dev/null
  systemctl enable --now systemd-resolved 2>/dev/null
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  log_success "Restaurado para systemd-resolved."
}

# --- Menu Principal ---
menu() {
  clear
  echo -e "${PURPLE}${BOLD}=============================================="
  echo -e "    DNSCrypt-Proxy: Otimizado para Notebooks"
  echo -e "==============================================${NC}"
  echo -e "${BOLD}1)${NC} ${CYAN}Instalar / Atualizar Binário${NC}"
  echo -e "   (Configura IP, Porta e Cache)"
  echo ""
  echo -e "${BOLD}2)${NC} ${GREEN}Gerenciar Blocklists${NC}"
  echo -e "   (Instalar, Atualizar, Agendar, Remover)"
  echo -e "   ${YELLOW}✓ Suporte para suspensão/hibernação${NC}"
  echo -e "----------------------------------------------"
  echo -e "${BOLD}3)${NC} Usar DNSCrypt no Sistema (Global)"
  echo -e "${BOLD}4)${NC} Restaurar DNS Padrão (Systemd)"
  echo -e "----------------------------------------------"
  echo -e "${BOLD}5)${NC} ${RED}Remover Tudo${NC}"
  echo -e "${BOLD}6)${NC} Sair"
  echo -e "${PURPLE}==============================================${NC}"
  read -p "Selecione uma opção: " opt

  case $opt in
    1) instalar_binario ;;
    2) gerenciar_blocklist ;;
    3) configurar_dns_global ;;
    4) restaurar_original ;;
    5) 
      systemctl stop dnscrypt-proxy 2>/dev/null
      desativar_agendamento
      rm -rf "$INSTALL_DIR"
      limpar_legados
      log_success "Removido completamente."
      ;;
    6) exit 0 ;;
  esac
  echo -e "\nPressione [Enter] para continuar..."
  read
}

verificar_root
while true; do menu; done
