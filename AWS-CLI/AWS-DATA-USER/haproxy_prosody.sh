#!/bin/bash

# Variables
HAPROXY_CFG_PATH="/etc/haproxy/haproxy.cfg"
BACKUP_CFG_PATH="/etc/haproxy/haproxy.cfg.bak"

# CONFIGURACION DUCKDNS

# SEBASTIAN
DUCKDNS_DOMAIN="prosodydiego.duckdns.org" # CAMBIAR POR DOMINIO DE PROSODY
DUCKDNS_TOKEN="55745a22-829a-4a73-bff2-9f9408a33578" # PONER TOKEN DE CUENTA

SSL_PATH="/etc/letsencrypt/live/$DUCKDNS_DOMAIN"
CERT_PATH="$SSL_PATH/fullchain.pem"
LOG_FILE="/var/log/script.log"

# Redirigir toda la salida a LOG_FILE
exec > >(tee -a $LOG_FILE) 2>&1

# CONFIGURAR DUCKDNS
mkdir -p /home/ubuntu/duckdns

cat <<EOL > /home/ubuntu/duckdns/duck.sh
echo url="https://www.duckdns.org/update?domains=$DUCKDNS_DOMAIN&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /home/ubuntu/duckdns/duck.log -K -
EOL

sudo chown ubuntu:ubuntu /home/ubuntu/duckdns/duck.sh
sudo chmod 700 /home/ubuntu/duckdns/duck.sh

# Agregar el cron job para ejecutar el script cada 5 minutos
(crontab -l 2>/dev/null; echo "*/5 * * * * /home/ubuntu/duckdns/duck.sh >/dev/null 2>&1") | crontab -

# Probar el script
sudo chmod +x /home/ubuntu/duckdns/duck.sh
sudo /home/ubuntu/duckdns/duck.sh

# Verificar el resultado del último intento
cat /home/ubuntu/duckdns/duck.log

# INSTALACION DE CERTBOT
sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install certbot -y

# CONFIGURACION DE LET'S ENCRYPT (Certbot)
if [ -f "$CERT_PATH" ]; then
    sudo certbot renew --non-interactive --quiet
else
    sudo certbot certonly --standalone -d $DUCKDNS_DOMAIN --non-interactive --agree-tos -m admin@$DUCKDNS_DOMAIN
fi

# FUSIONAR ARCHIVOS DE CERTIFICADO
sudo cat /etc/letsencrypt/live/$DUCKDNS_DOMAIN/fullchain.pem /etc/letsencrypt/live/$DUCKDNS_DOMAIN/privkey.pem | sudo tee /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem > /dev/null

# DAR PERMISOS AL CERTIFICADO
sudo chmod 644 /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem
sudo chmod 755 -R /etc/letsencrypt/live/$DUCKDNS_DOMAIN
sudo chmod 755 /etc/letsencrypt/live/

# INSTALACION DE HAPROXY
sudo apt-get update
sudo apt-get install -y haproxy

# COPIA DE SEGURIDAD DE LA CONFIGURACION INICIAL
sudo cp "$HAPROXY_CFG_PATH" "$BACKUP_CFG_PATH"

# CONFIGURACION DE HAPROXY
sudo tee "$HAPROXY_CFG_PATH" > /dev/null <<EOL
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

frontend xmpp_front
    bind *:5222 
    bind *:5269
    mode tcp
    default_backend xmpp_back

frontend http_xmpp
    bind *:80
    bind *:443 ssl crt /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem
    mode http
    redirect scheme https if !{ ssl_fc }
    default_backend http_back

backend xmpp_back
    mode tcp
    balance roundrobin
    server mensajeria1 10.203.3.20:5222 check
    server mensajeria2 10.203.3.20:5269 check
    server mensajeria3 10.203.3.20:5270 check

backend http_back
    mode http
    balance roundrobin
    server mensajeria4 10.203.3.20:80 check

backend db_back
    mode tcp
    balance roundrobin
    server db_primary 10.203.3.10:3306 check
    server db_secondary 10.203.3.11:3306 check backup
EOL

# REINICIAR Y HABILITAR HAPROXY
sudo systemctl restart haproxy
sudo systemctl enable haproxy

# VERIFICAR ESTADO DE HAPROXY
sudo systemctl status haproxy --no-pager

