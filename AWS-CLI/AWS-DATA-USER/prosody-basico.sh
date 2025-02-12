#!/bin/bash
# Instalación de Prosody y configuración de base de datos MySQL externa.

# Variables
db_host="10.203.3.10"
db_user="admin"
db_password="Admin123"
db_name="prosody"

LOG_FILE="/var/log/setup_script.log"

# Función para verificar que una instancia esté activa y en funcionamiento
check_instance_status() {
    instance_ip=$1
    status=$(aws ec2 describe-instance-status --instance-ids "$instance_ip" --query "InstanceStatuses[0].InstanceState.Name" --output text)
    while [ "$status" != "running" ]; do
        echo "Esperando a que la instancia con IP $instance_ip esté activa..." | tee -a $LOG_FILE
        sleep 10
        status=$(aws ec2 describe-instance-status --instance-ids "$instance_ip" --query "InstanceStatuses[0].InstanceState.Name" --output text)
    done
    echo "La instancia con IP $instance_ip está en funcionamiento." | tee -a $LOG_FILE
}

# Verificar el estado de las instancias de la base de datos
check_instance_status "10.203.3.10"
check_instance_status "10.203.3.11"

# Instalación de Prosody
echo "Instalando Prosody y módulos adicionales..." | tee -a $LOG_FILE
sudo apt update
sudo apt install lua-dbi-mysql lua-dbi-postgresql lua-dbi-sqlite3 -y 

# Configurar Prosody
echo "Configurando Prosody..." | tee -a $LOG_FILE
sudo tee /etc/prosody/prosody.cfg.lua > /dev/null <<EOL
-- Prosody Configuration

VirtualHost "prosodydiego.duckdns.org"
admins = { "admin@prosodydiego.duckdns.org" }

modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "dialback";
    "disco";
    "posix";
    "private";
    "vcard";
    "version";
    "uptime";
    "time";
    "ping";
    "register";
    "admin_adhoc";
}

allow_registration = true
daemonize = true
pidfile = "/var/run/prosody/prosody.pid"
c2s_require_encryption = true
s2s_require_encryption = true

log = {
    info = "/var/log/prosody/prosody.log";
    error = "/var/log/prosody/prosody.err";
    "*syslog";
}

storage = "sql"
sql = {
    driver = "MySQL";
    database = "$db_name";
    username = "$db_user";
    password = "$db_password";
    host = "$db_host";
}
EOL

# Reiniciar Prosody
echo "Reiniciando Prosody..." | tee -a $LOG_FILE
sudo systemctl restart prosody

# Crear usuario administrador
echo "Creando usuario admin@prosodydiego.duckdns.org..." | tee -a $LOG_FILE
sudo prosodyctl register admin prosodydiego.duckdns.org "Admin123"

echo "Prosody instalado y configurado con éxito en prosodydiego.duckdns.org" | tee -a $LOG_FILE
