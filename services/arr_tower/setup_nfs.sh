#!/usr/bin/env bash

set -euo pipefail

# 1. Cargar variables del archivo .env
ENV_FILE="./.env"

if [ -f "$ENV_FILE" ]; then
    echo "[INFO] Cargando variables desde $ENV_FILE..."
    # Exporta las variables del .env ignorando comentarios y líneas en blanco
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "[ERROR] El archivo $ENV_FILE no existe."
    exit 1
fi

# 2. Validar que las variables necesarias existan
if [ -z "${TRUENAS_IP:-}" ] || [ -z "${TRUENAS_MEDIA_PATH:-}" ]; then
    echo "[ERROR] TRUENAS_IP o TRUENAS_MEDIA_PATH no están definidas en $ENV_FILE."
    exit 1
fi

MOUNT_POINT="${LOCAL_MOUNT_MEDIA_PATH}"
NFS_SOURCE="${TRUENAS_IP}:${TRUENAS_MEDIA_PATH}"
FSTAB_ENTRY="${NFS_SOURCE}  ${MOUNT_POINT}  nfs  defaults,_netdev,nofail,bg  0  0"

echo "[INFO] Configurando NFS para la fuente: ${NFS_SOURCE}"

# 3. Instalar dependencias
echo "[INFO] Actualizando paquetes e instalando nfs-common..."
sudo apt update && sudo apt install -y nfs-common

# 4. Crear el punto de montaje
echo "[INFO] Creando el directorio local ${MOUNT_POINT}..."
sudo mkdir -p "${MOUNT_POINT}"

# 5. Probar el montaje manual
echo "[INFO] Probando montaje manual..."
if sudo mount -t nfs "${NFS_SOURCE}" "${MOUNT_POINT}"; then
    echo "[OK] Montaje exitoso."
else
    echo "[ERROR] Falló el montaje NFS de ${NFS_SOURCE} en ${MOUNT_POINT}."
    exit 1
fi

# 6. Verificar contenido de la carpeta
echo "[INFO] Verificando contenido en ${MOUNT_POINT}:"
ls -la "${MOUNT_POINT}"

# 7. Configuración de persistencia en /etc/fstab (Evita duplicados)
echo "[INFO] Configurando la entrada en /etc/fstab..."
if grep -qs "${MOUNT_POINT}" /etc/fstab; then
    echo "[WARN] Ya existe una entrada para ${MOUNT_POINT} en /etc/fstab. No se añadirá de nuevo."
else
    echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null
    echo "[OK] Línea añadida a /etc/fstab correctamente."
fi

echo "[ÉXITO] Configuración de NFS completada con éxito."