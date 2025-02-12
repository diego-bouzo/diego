#!/bin/bash
set -x  # Activar modo de depuración

# Variables
role="$1"  # "primary" o "secondary"
primary_ip="10.203.3.10"
secondary_ip="10.203.3.11"
db_user="admin"
db_password="Admin123"
db_name="prosody"
repl_user="replica"
repl_password="Admin123"

# 1. Instalar MySQL
sudo apt-get update > /dev/null
sudo apt-get install -y mysql-server mysql-client > /dev/null

# 2. Configurar replicación con GTID
sudo tee /etc/mysql/mysql.conf.d/replication.cnf > /dev/null <<EOF
[mysqld]
bind-address = 0.0.0.0
server-id = $( [ "$role" = "primary" ] && echo 1 || echo 2 )
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
relay-log = /var/log/mysql/mysql-relay-bin
log_slave_updates = 1

# Habilitar GTID
gtid_mode = ON
enforce-gtid-consistency = ON
EOF

# 3. Reiniciar servicio
sudo systemctl restart mysql

# 4. Configuracion básica de seguridad
sudo mysql -u root -p"$db_password" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$db_password';
CREATE DATABASE IF NOT EXISTS $db_name;
FLUSH PRIVILEGES;
EOF

# 5. Configuracion específica por rol
if [ "$role" = "primary" ]; then
    sudo mysql -u root -p"$db_password" <<EOF
    CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED WITH mysql_native_password BY '$db_password';
    GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'%';
    CREATE USER IF NOT EXISTS '$repl_user'@'%' IDENTIFIED WITH mysql_native_password BY '$repl_password';
    GRANT REPLICATION SLAVE ON *.* TO '$repl_user'@'%';
    FLUSH PRIVILEGES;
EOF

elif [ "$role" = "secondary" ]; then
    # Esperar conexion con primario
    until nc -z $primary_ip 3306; do sleep 10; done

    sudo mysql -u root -p"$db_password" <<EOF
    STOP SLAVE;
    RESET SLAVE ALL;
    CHANGE MASTER TO
    MASTER_HOST='$primary_ip',
    MASTER_USER='$repl_user',
    MASTER_PASSWORD='$repl_password',
    MASTER_AUTO_POSITION=1;
    START SLAVE;
EOF
fi

# 6. Habilitar servicio
sudo systemctl enable mysql > /dev/null
