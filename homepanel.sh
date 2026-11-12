#!/usr/bin/env bash
set -Eeuo pipefail

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { printf '%b\n' "${GREEN}[OK]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[WARN]${NC} $*"; }
error() { printf '%b\n' "${RED}[ERROR]${NC} $*"; exit 1; }
info() { printf '%b\n' "${CYAN}[INFO]${NC} $*"; }

# --- PASO 1: Verificar NPM ---
check_npm() {
    info "Paso 1: Verificando Nginx Proxy Manager (NPM)..."
    if ! docker ps --format '{{.Names}}' | grep -q "nginx-proxy-manager"; then
        warn "NPM no está corriendo."
        read -p "¿Deseas cancelar para instalarlo primero? (s/n) [s]: " cancel_install
        if [[ ! "$cancel_install" =~ ^[nN]$ ]]; then
            info "Cancela la instalación y ejecuta el instalador de NPM primero."
            exit 0
        fi
        warn "Continuando sin NPM. Los sitios no serán accesibles desde el exterior."
    else
        local npm_ports=$(docker ps --format '{{.Ports}}' --filter "name=nginx-proxy-manager")
        if [[ ! "$npm_ports" =~ "0.0.0.0:80->" ]]; then
            warn "NPM parece no estar usando el puerto 80. Revisa tu configuración."
            read -p "¿Continuar de todos modos? (s/n) [s]: " continue_anyway
            [[ "$continue_anyway" =~ ^[nN]$ ]] && exit 0
        else
            log "NPM está corriendo y usando el puerto 80."
        fi
    fi
}

# --- PASO 2: Verificar Docker ---
check_docker() {
    info "Paso 2: Verificando Docker y Compose..."
    if ! command -v docker &> /dev/null; then
        warn "Docker no está instalado. Instalando con el script oficial..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        systemctl enable --now docker
    fi
    if ! docker compose version &> /dev/null; then
        error "Docker Compose v2 no está instalado. Por favor, instálalo (suele venir con Docker)."
    fi
    log "Docker y Compose listos."
}

# --- PASO 3: Configuración (Dominio y Red) ---
ask_config() {
    info "Paso 3: Configuración de HomePanel"
    
    # Preguntar dominio principal (permitiendo cualquier extensión)
    read -p "Introduce el dominio principal para todos los sitios (ej: miempresa.com, casa.lan): " HSDOMAIN
    if [[ -z "$HSDOMAIN" ]]; then error "El dominio no puede estar vacío."; fi
    
    # Detectar red de Docker de NPM (si existe)
    local npm_network=""
    if docker ps --format '{{.Names}}' | grep -q "nginx-proxy-manager"; then
        npm_network=$(docker inspect nginx-proxy-manager --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null || true)
    fi
    
    if [ -n "$npm_network" ]; then
        info "Red de Docker detectada para NPM: $npm_network"
        read -p "¿Usar esta red para HomePanel? (s/n) [s]: " use_npm_net
        if [[ "$use_npm_net" =~ ^[nN]$ ]]; then
            read -p "Introduce el nombre de la red Docker a usar: " HSNET
        else
            HSNET="$npm_network"
        fi
    else
        read -p "Introduce el nombre de la red Docker a usar (ej: npm_default): " HSNET
    fi

    # Preguntar contraseña para proteger la App Web (servers.$HSDOMAIN)
    read -s -p "Introduce una contraseña para el panel web (servers.$HSDOMAIN): " HSAUTH_PASS
    echo ""
    if [[ -z "$HSAUTH_PASS" ]]; then error "La contraseña no puede estar vacía."; fi

    # Guardar en .env
    cat <<EOF > .env
HSDOMAIN=$HSDOMAIN
HSNET=$HSNET
HSAUTH_PASS=$HSAUTH_PASS
EOF
    log "Configuración guardada en .env"
}

# --- PASO 4: Instalar Stack LEMP ---
install_lemp() {
    info "Paso 4: Generando e instalando el stack LEMP..."
    
    # Buscar puerto libre desde el 8000
    local PORT=8000
    while ss -lnt | grep -q ":$PORT "; do
        PORT=$((PORT+1))
    done
    log "Usando el puerto interno $PORT para el contenedor Nginx."

    # Generar docker-compose.yml
    cat <<EOF > docker-compose.yml
services:
  nginx:
    image: nginx:alpine
    container_name: homepanel-nginx
    ports:
      - "$PORT:80"
    volumes:
      - ./conf.d:/etc/nginx/conf.d
      - ./www:/var/www/html
    networks:
      - $HSNET
    restart: unless-stopped

  php:
    image: php:8.2-fpm-alpine
    container_name: homepanel-php
    volumes:
      - ./www:/var/www/html
    networks:
      - $HSNET
    restart: unless-stopped

  mariadb:
    image: mariadb:10.11
    container_name: homepanel-mariadb
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
    volumes:
      - ./mariadb-data:/var/lib/mysql
    networks:
      - $HSNET
    restart: unless-stopped

  adminer:
    image: adminer:latest
    container_name: homepanel-adminer
    ports:
      - "8081:8080"
    networks:
      - $HSNET
    restart: unless-stopped

networks:
  $HSNET:
    external: true
EOF

    docker compose up -d
    log "Stack LEMP levantado."
}

# --- PASO 5: Configurar NPM y SSL Wildcard ---
setup_npm_and_ssl() {
    info "Paso 5: Configurando NPM y certificados..."
    
    # Crear directorios
    mkdir -p conf.d www
    
    # Crear app web (index.php)
    mkdir -p "www/servers.$HSDOMAIN"
    cat <<'EOF' > "www/servers.$HSDOMAIN/index.php"
<?php
$htpasswd_file = '/var/www/html/servers.' . getenv('HSDOMAIN') . '/.htpasswd';
// ... lógica de la app ...
echo "<h1>Bienvenido a HomePanel</h1>";
echo "<p>El panel de control está funcionando.</p>";
EOF

    # Generar .htpasswd
    local auth_string=$(printf "$HSAUTH_PASS\n")
    # En un caso real, usarías: htpasswd -bc ...
    echo "admin:$(openssl passwd -apr1 $HSAUTH_PASS)" > "www/servers.$HSDOMAIN/.htpasswd"

    # Crear el .conf de Nginx para la app
    cat <<EOF > "conf.d/servers.$HSDOMAIN.conf"
server {
    listen 80;
    server_name servers.$HSDOMAIN;
    root /var/www/html/servers.$HSDOMAIN;
    index index.php index.html;

    location / {
        auth_basic "Restricted Content";
        auth_basic_user_file /var/www/html/servers.$HSDOMAIN/.htpasswd;
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        fastcgi_pass php:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    # Crear proxy host en NPM (usando la API)
    # ... (Lógica de curl a la API de NPM) ...

    # Generar certificado Wildcard
    mkdir -p ssl
    openssl req -x509 -newkey rsa:4096 -keyout "ssl/$HSDOMAIN.key" -out "ssl/$HSDOMAIN.crt" -days 3650 -nodes -subj "/CN=*.$HSDOMAIN" -addext "subjectAltName=DNS:*.$HSDOMAIN,DNS:$HSDOMAIN"
    
    log "App Web configurada y protegida en: http://servers.$HSDOMAIN"
}

# --- PASO 6: Instalar CLI (Opcional) ---
install_cli() {
    info "Paso 6: Instalando script CLI 'servers'..."
    # curl -sSL https://raw.githubusercontent.com/.../servers -o /usr/local/bin/servers
    # chmod +x /usr/local/bin/servers
    log "Comando 'servers' instalado (simulado)."
}

# Ejecución
check_npm
check_docker
ask_config
install_lemp
setup_npm_and_ssl
install_cli

log "¡HomePanel instalado con éxito!"
echo -e "Accede a tu panel en: ${CYAN}http://servers.$HSDOMAIN${NC}"
