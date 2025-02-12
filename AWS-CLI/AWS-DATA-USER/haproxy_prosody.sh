#!/bin/bash

# Creamos las variables del script del proxy inverso que vamos a utilizar en nuestro caso es el HAProxy
HAPROXY_CFG_PATH="/etc/haproxy/haproxy.cfg"
BACKUP_CFG_PATH="/etc/haproxy/haproxy.cfg.bak"

# CONFIGURACION DUCKDNS

# Ponemos los dominios que hemos creado previamente en duckdns
DUCKDNS_DOMAIN="prosodydiego.duckdns.org" # CAMBIAR POR DOMINIO DE PROSODY
DUCKDNS_TOKEN="55745a22-829a-4a73-bff2-9f9408a33578" # PONER TOKEN DE CUENTA

# Defiminos la ruta donde se guardaran las claves del dominio
SSL_PATH="/etc/letsencrypt/live/$DUCKDNS_DOMAIN"
CERT_PATH="$SSL_PATH/fullchain.pem"
LOG_FILE="/var/log/script.log"

# Redirigir toda la salida a LOG_FILE
exec > >(tee -a $LOG_FILE) 2>&1

# Comenzamos a configurar el duckdns
mkdir -p /home/ubuntu/duckdns

cat <<EOL > /home/ubuntu/duckdns/duck.sh
echo url="https://www.duckdns.org/update?domains=$DUCKDNS_DOMAIN&token=$DUCKDNS_TOKEN&ip=" | curl -k -o /home/ubuntu/duckdns/duck.log -K -
EOL

# Damos los permisos necesarios para ejecutar el script de duckdns

sudo chown ubuntu:ubuntu /home/ubuntu/duckdns/duck.sh
sudo chmod 700 /home/ubuntu/duckdns/duck.sh

# Agregamos el cron job para ejecutar el script cada 5 minutos
(crontab -l 2>/dev/null; echo "*/5 * * * * /home/ubuntu/duckdns/duck.sh >/dev/null 2>&1") | crontab -

# Probamos el script
sudo chmod +x /home/ubuntu/duckdns/duck.sh
sudo /home/ubuntu/duckdns/duck.sh

# Verificamos el resultado del último intento
cat /home/ubuntu/duckdns/duck.log

# Instalamos el certbot
sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install certbot -y

# Configuramos let'encrypt para obtener las claves del dominio (Certbot)
if [ -f "$CERT_PATH" ]; then
    sudo certbot renew --non-interactive --quiet
else
    sudo certbot certonly --standalone -d $DUCKDNS_DOMAIN --non-interactive --agree-tos -m admin@$DUCKDNS_DOMAIN
fi

# Fusionamos las claves para crear una nueva
sudo cat /etc/letsencrypt/live/$DUCKDNS_DOMAIN/fullchain.pem /etc/letsencrypt/live/$DUCKDNS_DOMAIN/privkey.pem | sudo tee /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem > /dev/null

# Damos los permisos necesarios
sudo chmod 644 /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem
sudo chmod 755 -R /etc/letsencrypt/live/$DUCKDNS_DOMAIN
sudo chmod 755 /etc/letsencrypt/live/

# Comenzamos la instalacion de HAProxy
sudo apt-get update
sudo apt-get install -y haproxy

# Hacemos una copia de seguridad de la configuracion inical
sudo cp "$HAPROXY_CFG_PATH" "$BACKUP_CFG_PATH"

# Comenzamos la configuracion
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

# Definimos con los frontend los puertos que queremos que pasen a traves del proxy junto con la ip del servidor

frontend xmpp_front
    bind *:5222       # Este puerto permite la comunicacion entre los usuarios
    bind *:5269       # Este puerto permite la conexion del servidor xmpp en nuestro caso el prosody
    mode tcp
    default_backend xmpp_back       # Esta linea es el sitio al que iran las solicitudes de los puertos

frontend http_xmpp
    bind *:80         # Este puerto permite el acceso http
    bind *:443 ssl crt /etc/letsencrypt/live/$DUCKDNS_DOMAIN/haproxy.pem        # Este puerto permite el acceso al servidor web mediante tls
    mode http
    redirect scheme https if !{ ssl_fc }
    default_backend http_back

# Definimos con los backend la ip del servidor (xmpp-prosody) junto con los puertos previamente definidos en los frontend y sus balances de carga

backend xmpp_back
    mode tcp
    balance roundrobin  # El balance de carga round robin distribuye el tráfico a una lista de servidores en rotación con el Sistema de nombres de dominio (DNS).
    server mensajeria1 10.203.3.20:5222 check   # Definimos el servidor con un nombre, la ip y el puerto
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
    server db_secondary 10.203.3.11:3306 check backup   # Esta linea significa que si el primario se cae el secundario tomara el rol de primario
EOL

# Reiniciamos HAProxy
sudo systemctl restart haproxy
sudo systemctl enable haproxy

# Verificamos el estado
sudo systemctl status haproxy --no-pager

