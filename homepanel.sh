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
            info "Cancelando instalación. Por favor, instala NPM en el puerto 80 primero."
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

# --- PASO 3: Configuración (Dominio, Red y Credenciales) ---
ask_config() {
    info "Paso 3: Configuración de HomePanel"

    read -p "Introduce el dominio principal (ej: miempresa.com, casa.lan): " HSDOMAIN
    if [[ -z "$HSDOMAIN" ]]; then error "El dominio no puede estar vacío."; fi

    # Detectar red de Docker de NPM
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

    read -s -p "Introduce una contraseña para el panel web (servers.$HSDOMAIN): " HSAUTH_PASS
    echo ""
    if [[ -z "$HSAUTH_PASS" ]]; then error "La contraseña no puede estar vacía."; fi

    # Preguntar credenciales de NPM para la API
    info "Configuración de la API de NPM (necesario para automatizar los hosts):"
    read -p "Email de administrador de NPM [admin@example.com]: " NPM_USER
    NPM_USER=${NPM_USER:-admin@example.com}

    read -s -p "Contraseña de administrador de NPM: " NPM_PASS
    echo ""
    if [[ -z "$NPM_PASS" ]]; then error "La contraseña de NPM no puede estar vacía."; fi

    # Guardar todo en .env, incluyendo UID y GID
    cat <<EOF > .env
HSDOMAIN=$HSDOMAIN
HSNET=$HSNET
HSAUTH_PASS=$HSAUTH_PASS
NPM_USER=$NPM_USER
NPM_PASS=$NPM_PASS
UID=$(id -u)
GID=$(id -g)
EOF
    log "Configuración guardada en .env"
}

# --- PASO 4: Instalar Stack LEMP ---
install_lemp() {
    info "Paso 4: Generando e instalando el stack LEMP..."

    # Asegurar que la red externa existe antes de levantar docker-compose
    if ! docker network ls --format '{{.Name}}' | grep -q "^$HSNET$"; then
        warn "La red Docker '$HSNET' no existe. Creándola..."
        docker network create "$HSNET"
    fi

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
    user: "\${UID:-1000}:\${GID:-1000}"
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

# --- PASO 5: Configurar NPM y App Web ---
setup_npm_and_app() {
    info "Paso 5: Configurando la App Web y NPM..."

    mkdir -p conf.d www "www/servers.$HSDOMAIN"

    # 1. Crear el index.php de la App (esqueleto)
    cat <<'EOF' > "www/servers.$HSDOMAIN/index.php"
<?php
echo "<h1>Bienvenido a HomePanel</h1>";
echo "<p>El panel de control está funcionando.</p>";
EOF

    # 2. Crear archivo .htpasswd usando openssl
    local hashed_pass=$(openssl passwd -apr1 "$HSAUTH_PASS")
    echo "admin:$hashed_pass" > "www/servers.$HSDOMAIN/.htpasswd"

    # 3. Crear el .conf de Nginx para la app (con autenticación básica)
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
        fastcgi_pass homepanel-php:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    # Recargar Nginx para aplicar el nuevo .conf
    docker exec homepanel-nginx nginx -s reload

    # 4. Crear Proxy Host en NPM
    info "Creando Proxy Host en NPM para servers.$HSDOMAIN..."

    local npm_url="http://nginx-proxy-manager:81"

    # Autenticación en NPM (usando las credenciales guardadas)
    local token=$(curl -s -X POST "$npm_url/api/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\": \"$NPM_USER\", \"secret\": \"$NPM_PASS\"}" | grep -oP '(?<="token": ")[^"]*' || true)

    if [ -n "$token" ]; then
        # Crear el proxy host apuntando al contenedor Nginx
        curl -s -X POST "$npm_url/api/nginx/proxy-hosts" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d "{
                \"domain_names\": [\"servers.$HSDOMAIN\"],
                \"forward_scheme\": \"http\",
                \"forward_host\": \"homepanel-nginx\",
                \"forward_port\": $PORT,
                \"access_list_id\": 0,
                \"certificate_id\": 0,
                \"ssl_forced\": false,
                \"meta\": {\"letsencrypt_agree\": false, \"letsencrypt_email\": \"\"},
                \"advanced_config\": \"\",
                \"locations\": [],
                \"block_exploits\": true,
                \"caching_enabled\": false,
                \"allow_websocket_upgrade\": true,
                \"http2_support\": false,
                \"hsts_enabled\": false,
                \"hsts_subdomains\": false
            }" > /dev/null
        log "Proxy Host creado en NPM."
    else
        warn "No se pudo autenticar en NPM. Comprueba tus credenciales."
        warn "Crea el Proxy Host manualmente para servers.$HSDOMAIN apuntando al puerto $PORT."
    fi

    # 5. Generar Certificado Wildcard (Local)
    mkdir -p ssl
    openssl req -x509 -newkey rsa:4096 -keyout "ssl/$HSDOMAIN.key" -out "ssl/$HSDOMAIN.crt" -days 3650 -nodes -subj "/CN=*.$HSDOMAIN" -addext "subjectAltName=DNS:*.$HSDOMAIN,DNS:$HSDOMAIN"
    log "Certificado wildcard generado en ./ssl"
}

# --- PASO 6: Instalar CLI ---
install_cli() {
    info "Paso 6: Instalando script CLI 'servers'..."
    curl -sSL https://raw.githubusercontent.com/jernesten/HomePanel/main/servers -o /usr/local/bin/servers
    chmod +x /usr/local/bin/servers
    log "Comando 'servers' instalado."
}

# Ejecución
check_npm
check_docker
ask_config
install_lemp
setup_npm_and_app
install_cli

log "¡HomePanel instalado con éxito!"
echo -e "Accede a tu panel en: ${CYAN}http://servers.$HSDOMAIN${NC} (Usuario: admin)"
