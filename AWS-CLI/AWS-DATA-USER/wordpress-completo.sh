#!/bin/bash
##############################
#  INSTALACION WP / PLUGINS  #
##############################

# Variables
WP_PATH="/var/www/html"
WP_URL="https://srestrepoj-wordpress.duckdns.org"
ROLE_NAME="cliente_soporte"
SSL_CERT="/etc/apache2/ssl/srestrepoj-wordpress.duckdns.org/fullchain.pem"
SSL_KEY="/etc/apache2/ssl/srestrepoj-wordpress.duckdns.org/privkey.pem"
LOG_FILE="/var/log/wp_install.log"
# Funcion para registrar mensajes
log() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Funcion para esperar a que la base de datos esté disponible
wait_for_db() {
    log "Esperando a que la base de datos este disponible en $RDS_ENDPOINT..."
    while ! mysql -h "$RDS_ENDPOINT" -u "$DB_USERNAME" -p"$DB_PASSWORD" -e "SELECT 1" &>/dev/null; do
        log "Base de datos no disponible, esperando 10 segundos..."
        sleep 10
    done
    log "Base de datos disponible!"
}

# Esperar a que la base de datos esté disponible
wait_for_db

# Actualizar e instalar dependencias necesarias
log "Actualizando paquetes e instalando dependencias..."
sudo apt update
sudo add-apt-repository universe -y
sudo apt install -y apache2 mysql-client php php-mysql libapache2-mod-php php-curl php-xml php-mbstring php-zip curl git unzip

# Instalar WP-CLI
log "Instalando WP-CLI..."
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# Limpiar el directorio de Apache
log "Limpiando el directorio de Apache..."
sudo rm -rf /var/www/html/*
sudo chmod -R 755 /var/www/html
sudo chown -R ubuntu:ubuntu /var/www/html

# Crear base de datos y usuario, si no existen
log "Creando base de datos y usuario (si no existe)..."
mysql -h $RDS_ENDPOINT -u $DB_USERNAME -p$DB_PASSWORD <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USERNAME'@'%';
FLUSH PRIVILEGES;

# Descargar WordPress
log "Descargando WordPress..."
wp core download --path=/var/www/html

# Eliminar el archivo wp-config.php existente si hay uno
rm -f /var/www/html/wp-config.php

# Configurar wp-config.php
log "Configurando wp-config.php..."
wp core config --dbname="$DB_NAME" --dbuser="$DB_USERNAME" --dbpass="$DB_PASSWORD" --dbhost="$RDS_ENDPOINT" --dbprefix=wp_ --path=/var/www/html

# Instalar WordPress
log "Instalando WordPress..."
wp core install --url="$WP_URL" --title="CMS - TICKETING" --admin_user="$DB_USERNAME" --admin_password="$DB_PASSWORD" --admin_email="srestrepoj01@educantabria.es" --path=/var/www/html

# Instalar plugins adicionales
log "Instalando plugins..."
wp plugin install supportcandy --activate --path=/var/www/html
wp plugin install user-registration --activate --path=/var/www/html

# Crear paginas de registro y soporte
log "Creando paginas de registro y soporte..."
REGISTER_PAGE_ID=$(wp post create --post_title="Registro de Usuarios" --post_content="[user_registration_form]" --post_status="publish" --post_type="page" --path=/var/www/html --porcelain)
SUPPORT_PAGE_ID=$(wp post create --post_title="Soporte de Tickets" --post_content="[supportcandy]" --post_status="publish" --post_type="page" --path=/var/www/html --porcelain)

# Habilitar el registro de usuarios
wp option update users_can_register 1 --path=/var/www/html
wp option update default_role "subscriber" --path=/var/www/html

# Crear rol personalizado "Cliente de soporte"
log "Creando rol personalizado 'Cliente de soporte'..."
wp role create "$ROLE_NAME" "Cliente de soporte" --path=/var/www/html
wp role add_cap "$ROLE_NAME" "read" --path=/var/www/html
wp role add_cap "$ROLE_NAME" "create_ticket" --path=/var/www/html
wp role add_cap "$ROLE_NAME" "view_own_ticket" --path=/var/www/html

# Configurar Apache para WordPress con SSL
log "Configurando Apache para WordPress con SSL..."
sudo bash -c "cat > /etc/apache2/sites-available/wordpress.conf <<APACHE
<VirtualHost *:443>
    ServerAdmin admin@srestrepoj-wordpress.duckdns.org
    ServerName  srestrepoj-wordpress.duckdns.org

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile $SSL_CERT
    SSLCertificateKeyFile $SSL_KEY

    <Directory /var/www/html>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHE"

# Habilitar el sitio de WordPress y reiniciar Apache
log "Reiniciando Apache..."
sudo a2dissite 000-default.conf
sudo a2ensite wordpress.conf
sudo a2enmod rewrite ssl
sudo systemctl restart apache2

log "¡Instalación completada! Accede a tu WordPress en: $WP_URL"