#!/bin/bash

# ARCHIVO DE LOG
LOG_FILE="laboratorio.log"
# Redirigir toda la salida al archivo de log


###########################################                       
#            VARIABLES DE PRUEBA          #
###########################################

# Variables VPC
read -r -p "Pon el nombre del laboratorio: " NOMBRE_ALUMNO
REGION="us-east-1"
# Variables AMI-ID (Ubuntu server 24.04) y CLAVE SSH
KEY_NAME="ssh-mensagl-2025-${NOMBRE_ALUMNO}"
AMI_ID="ami-04b4f1a9cf54c11d0" # Llamar variable claves         

# Crear par de claves SSH y almacenar la clave en una variable
PEM_KEY=$(aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --query "KeyMaterial" \
    --output text)

# Guardar la clave en un archivo
echo "${PEM_KEY}" > "${KEY_NAME}.pem"
chmod 400 "${KEY_NAME}.pem"
echo "Clave SSH creada y almacenada en: ${KEY_NAME}.pem"

# Usar la variable PEM_KEY en otros comandos
echo "Contenido de la clave SSH almacenada en variable:"
echo "${PEM_KEY}"


# Variables para RDS, se pueden cambiar los valores por los deseados
RDS_INSTANCE_ID="wordpress-db"
read -r -p "Ingrese el nombre de la instancia RDS / BD: " DB_NAME
read -r -p "Ingrese el nombre de usuario de la BD: " DB_USERNAME
read -r -p "Ingrese la contraseña de la BD: " DB_PASSWORD


exec > "$LOG_FILE" 2>&1

##############################                       
#             VPC            #
##############################

# Crear VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block "10.203.0.0/16" --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="vpc-mensagl-2025-${NOMBRE_ALUMNO}"

# Crear Subnets publicas
SUBNET_PUBLIC1_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.203.1.0/24" --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
SUBNET_PUBLIC2_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.203.2.0/24" --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)

# Crear Subnets privadas
SUBNET_PRIVATE1_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.203.3.0/24" --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
SUBNET_PRIVATE2_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "10.203.4.0/24" --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)

# Crear Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

# Crear Tabla de Rutas Públicas
RTB_PUBLIC_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PUBLIC_ID" --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PUBLIC1_ID" --route-table-id "$RTB_PUBLIC_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PUBLIC2_ID" --route-table-id "$RTB_PUBLIC_ID"

# Crear Elastic IP y NAT Gateway
EIP_ID=$(aws ec2 allocate-address --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$SUBNET_PUBLIC1_ID" --allocation-id "$EIP_ID" --query 'NatGateway.NatGatewayId' --output text)

echo "Creando GATEWAY NAT..."
while true; do
    STATUS=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text)
    echo "Estado del NAT Gateway: $STATUS"
    if [ "$STATUS" == "available" ]; then
        break
    fi
    sleep 10
done

# Crear Tabla de Rutas Privadas
RTB_PRIVATE1_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PRIVATE1_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PRIVATE1_ID" --route-table-id "$RTB_PRIVATE1_ID"

RTB_PRIVATE2_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RTB_PRIVATE2_ID" --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_ID"
aws ec2 associate-route-table --subnet-id "$SUBNET_PRIVATE2_ID" --route-table-id "$RTB_PRIVATE2_ID"

##############################                       
# Crear Grupos de Seguridad  #
##############################

# Grupo de seguridad para los Proxy Inversos - Wordpress
SG_PROXY_WP_ID=$(aws ec2 create-security-group --group-name "sg_proxy_inverso-WP" --description "SG para el proxy inverso - wordpress" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_WP_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_WP_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_WP_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_PROXY_WP_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para los Proxy Inversos - Prosody
SG_PROXY_PROSODY_ID=$(aws ec2 create-security-group --group-name "sg_proxy_inverso-Prosody" --description "SG para el proxy inverso - prosody" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_PROSODY_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_PROSODY_ID" --protocol tcp --port 5222 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_PROSODY_ID" --protocol tcp --port 5269 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_PROSODY_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_PROXY_PROSODY_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id  "$SG_PROXY_PROSODY_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para el CMS
SG_CMS_ID=$(aws ec2 create-security-group --group-name "sg_cms" --description "SG para el cluster CMS" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 33060 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_CMS_ID" --protocol tcp --port 53 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_CMS_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para MySQL
SG_MYSQL_ID=$(aws ec2 create-security-group --group-name "sg_mysql" --description "SG para servidores MySQL" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 3306 --source-group "$SG_MYSQL_ID"
aws ec2 authorize-security-group-ingress --group-id "$SG_MYSQL_ID" --protocol tcp --port 3306 --cidr "$(aws ec2 describe-subnets --subnet-ids "$SUBNET_PRIVATE1_ID" --query 'Subnets[0].CidrBlock' --output text)"
aws ec2 authorize-security-group-egress --group-id "$SG_MYSQL_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

# Grupo de seguridad para Mensajeria (XMPP Prosody + MySQL)
SG_MENSAJERIA_ID=$(aws ec2 create-security-group --group-name "sg_mensajeria" --description "SG para XMPP Prosody y MySQL" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5222 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5347 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 3306 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol udp --port 10000 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5269 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5270 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 4443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5281 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 5280 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SG_MENSAJERIA_ID" --protocol tcp --port 443 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SG_MENSAJERIA_ID" --protocol -1 --port all --cidr "0.0.0.0/0"

##############################                       
#             RDS             #
##############################

# Crear subnet RD
aws rds create-db-subnet-group \
    --db-subnet-group-name wp-rds-subnet-group \
    --db-subnet-group-description "RDS Subnet Group for WordPress" \
    --subnet-ids "$SUBNET_PRIVATE1_ID" "$SUBNET_PRIVATE2_ID"


# SG de RDS
SG_ID_RDS=$(aws ec2 create-security-group \
  --group-name "RDS-MySQL" \
  --description "SG para RDS MySQL" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' \
  --output text)

# Permitir acceso MySQL
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID_RDS" \
  --protocol tcp \
  --port 3306 \
  --cidr 0.0.0.0/0  

# Crear instancia RDS (Single-AZ en Private Subnet 2)
aws rds create-db-instance \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --db-instance-class db.t3.medium \
    --engine mysql \
    --allocated-storage 20 \
    --storage-type gp2 \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --db-subnet-group-name wp-rds-subnet-group \
    --vpc-security-group-ids "$SG_ID_RDS" \
    --backup-retention-period 7 \
    --no-publicly-accessible \
    --availability-zone "us-east-1b" \
    --no-multi-az  # Se asegura que no se despliega en multiple AZ

# ESPERA A QUE EL RDS ESTE DISPONIBLE
echo "ESPERANDO A QUE EL RDS ESTE DISPONIBLE..."
aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"

# Recibe el RDS ENDPOINT PARA USARLO MAS ADELANTE
RDS_ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_INSTANCE_ID" \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"

##################################################                       
#             INSTANCIAS Y SERVICIOS             #
##################################################
# proxy-prosody
INSTANCE_NAME="proxy-prosody"
SUBNET_ID="${SUBNET_PUBLIC1_ID}"
SECURITY_GROUP_ID="${SG_PROXY_PROSODY_ID}"
PRIVATE_IP="10.203.1.10"
INSTANCE_TYPE="t2.micro"
VOLUME_SIZE=8

USER_DATA_SCRIPT=$(cat <<EOF
#!/bin/bash
# CAMBIAR LINK DE DESCARGA
sudo curl -o /home/ubuntu/setup.sh https://raw.githubusercontent.com/diego-bouzo/diego/refs/heads/main/AWS-CLI/AWS-DATA-USER/haproxy_prosody.sh
sudo chown ubuntu:ubuntu setup.sh
sudo chmod +x /home/ubuntu/setup.sh
sudo bash /home/ubuntu/setup.sh

# Configurar la clave SSH
sudo mkdir -p /home/ubuntu/.ssh
sudo echo "${PEM_KEY}" > /home/ubuntu/.ssh/${KEY_NAME}.pem
sudo chmod 400 /home/ubuntu/.ssh/${KEY_NAME}.pem
sudo chown ubuntu:ubuntu /home/ubuntu/.ssh/${KEY_NAME}.pem

# Copiar A prosody, para configurarlo en ambas instancias del cluster
sudo scp -i "/home/ubuntu/.ssh/${KEY_NAME}.pem" -r /etc/letsencrypt/live/prosodydiego.duckdns.org ubuntu@10.203.3.20:/home/ubuntu
sudo scp -i "/home/ubuntu/.ssh/${KEY_NAME}.pem" -r /etc/letsencrypt/live/prosodydiego.duckdns.org ubuntu@10.203.3.30:/home/ubuntu

EOF
)
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# proxy-wordpress
INSTANCE_NAME="proxy-wordpress"
SUBNET_ID="${SUBNET_PUBLIC2_ID}"
PRIVATE_IP="10.203.2.10"
INSTANCE_TYPE="t2.micro"
SECURITY_GROUP_ID="${SG_PROXY_WP_ID}"
VOLUME_SIZE=8

USER_DATA_SCRIPT=$(cat <<EOF
#!/bin/bash
# CAMBIAR LINK DE DESCARGA
sudo curl -o /home/ubuntu/setup.sh https://raw.githubusercontent.com/diego-bouzo/diego/refs/heads/main/AWS-CLI/AWS-DATA-USER/haproxy_wordpress.sh
sudo chown ubuntu:ubuntu setup.sh
sudo chmod +x /home/ubuntu/setup.sh
sudo bash /home/ubuntu/setup.sh

# Configurar la clave SSH
sudo mkdir -p /home/ubuntu/.ssh
sudo echo "${PEM_KEY}" > /home/ubuntu/.ssh/${KEY_NAME}.pem
sudo chmod 400 /home/ubuntu/.ssh/${KEY_NAME}.pem
sudo chown ubuntu:ubuntu /home/ubuntu/.ssh/${KEY_NAME}.pem

# Copiar A wordpress, para configurarlo, en ambas instancias del cluster
sudo scp -i "/home/ubuntu/.ssh/${KEY_NAME}.pem" -r /etc/letsencrypt/live/wordpressdiego.duckdns.org ubuntu@10.203.4.10:/home/ubuntu
sudo scp -i "/home/ubuntu/.ssh/${KEY_NAME}.pem" -r /etc/letsencrypt/live/wordpressdiego.duckdns.org ubuntu@10.203.4.11:/home/ubuntu
EOF
)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,AssociatePublicIpAddress=true,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"


##############
#    MySQL   #
##############
# sgbd_principal
INSTANCE_NAME="sgbd_principal-zona1"
SUBNET_ID="${SUBNET_PRIVATE1_ID}"
SECURITY_GROUP_ID="${SG_MYSQL_ID}"
PRIVATE_IP="10.203.3.10"

# Cargar el script para la base de datos primaria
USER_DATA_SCRIPT=$(sed 's/role=".*"/role="primary"/' AWS-DATA-USER/configuracion-bd-primaria-y-slave.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# sgbd_secundario
INSTANCE_NAME="sgbd_replica-zona1"
PRIVATE_IP="10.203.3.11"

# Cargar el script para la base de datos secundaria
USER_DATA_SCRIPT=$(sed 's/role=".*"/role="secondary"/' AWS-DATA-USER/configuracion-bd-primaria-y-slave.sh)

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"


##############
#    XMPP    #
#############
# mensajeria-1
INSTANCE_NAME="mensajeria-1"
SUBNET_ID="${SUBNET_PRIVATE1_ID}"
SECURITY_GROUP_ID="${SG_MENSAJERIA_ID}"
PRIVATE_IP="10.203.3.20"
USER_DATA_SCRIPT=$(cat <<EOF
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
EOF
)
 INSTANCE_ID=$(aws ec2 run-instances \
     --image-id "$AMI_ID" \
     --instance-type "t2.medium" \
     --key-name "$KEY_NAME" \
     --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
     --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
     --user-data "$USER_DATA_SCRIPT" \
     --query "Instances[0].InstanceId" \
     --output text)
 echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# mensajeria-2
INSTANCE_NAME="mensajeria-2"
SUBNET_ID="${SUBNET_PRIVATE1_ID}"
SECURITY_GROUP_ID="${SG_MENSAJERIA_ID}"
PRIVATE_IP="10.203.3.30"
USER_DATA_SCRIPT=$(cat <<EOF
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
EOF
)
 INSTANCE_ID=$(aws ec2 run-instances \
     --image-id "$AMI_ID" \
     --instance-type "t2.medium" \
     --key-name "$KEY_NAME" \
     --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
     --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
     --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
     --user-data "$USER_DATA_SCRIPT" \
     --query "Instances[0].InstanceId" \
     --output text)
 echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

##############
# WORDPRESS  #
##############
# soporte-1
INSTANCE_NAME="soporte-1"
SUBNET_ID="${SUBNET_PRIVATE2_ID}"
SECURITY_GROUP_ID="${SG_CMS_ID}"
PRIVATE_IP="10.203.4.10"

USER_DATA_SCRIPT=$(cat <<EOF
#!/bin/bash
##############################
#  INSTALACION WP / PLUGINS  #
##############################

# Variables
WP_PATH="/var/www/html"
WP_URL="https://wordpressdiego.duckdns.org"
ROLE_NAME="cliente_soporte"
SSL_CERT="/etc/apache2/ssl/wordpressdiego.duckdns.org/fullchain.pem"
SSL_KEY="/etc/apache2/ssl/wordpressdiego.duckdns.org/privkey.pem"
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
wp role cap "$ROLE_NAME" "read" --path=/var/www/html
wp role cap "$ROLE_NAME" "create_ticket" --path=/var/www/html
wp role cap "$ROLE_NAME" "view_own_ticket" --path=/var/www/html

# Configurar Apache para WordPress con SSL
log "Configurando Apache para WordPress con SSL..."
sudo bash -c "cat > /etc/apache2/sites-available/wordpress.conf <<APACHE
<VirtualHost *:443>
    ServerAdmin admin@wordpressdiego.duckdns.org
    ServerName  wordpressdiego.duckdns.org

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
EOF
)
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"

# soporte-2
INSTANCE_NAME="soporte-2"
SUBNET_ID="${SUBNET_PRIVATE2_ID}"
SECURITY_GROUP_ID="${SG_CMS_ID}"
PRIVATE_IP="10.203.4.11"

USER_DATA_SCRIPT=$(cat <<EOF
#!/bin/bash
##############################
#  INSTALACION WP / PLUGINS  #
##############################

# Variables
WP_PATH="/var/www/html"
WP_URL="https://wordpressdiego.duckdns.org"
ROLE_NAME="cliente_soporte"
SSL_CERT="/etc/apache2/ssl/wordpressdiego.duckdns.org/fullchain.pem"
SSL_KEY="/etc/apache2/ssl/wordpressdiego.duckdns.org/privkey.pem"
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

# Habilitar el registro de usuarios
wp option update users_can_register 1 --path=/var/www/html
wp option update default_role "subscriber" --path=/var/www/html

# Crear rol personalizado "Cliente de soporte"
log "Creando rol personalizado 'Cliente de soporte'..."
wp role create "$ROLE_NAME" "Cliente de soporte" --path=/var/www/html
wp role cap "$ROLE_NAME" "read" --path=/var/www/html
wp role cap "$ROLE_NAME" "create_ticket" --path=/var/www/html
wp role cap "$ROLE_NAME" "view_own_ticket" --path=/var/www/html

# Configurar Apache para WordPress con SSL
log "Configurando Apache para WordPress con SSL..."
sudo bash -c "cat > /etc/apache2/sites-available/wordpress.conf <<APACHE
<VirtualHost *:443>
    ServerAdmin admin@wordpressdiego.duckdns.org
    ServerName  wordpressdiego.duckdns.org

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
EOF
)
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
    --network-interfaces "SubnetId=$SUBNET_ID,DeviceIndex=0,PrivateIpAddresses=[{Primary=true,PrivateIpAddress=$PRIVATE_IP}],Groups=[$SECURITY_GROUP_ID]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --user-data "$USER_DATA_SCRIPT" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "${INSTANCE_NAME} creada: ${INSTANCE_ID}"
