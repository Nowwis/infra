#!/bin/sh
set -e
sed "s|#ADMIN_FOLDER_PRESTASHOP#|${ADMIN_FOLDER_PRESTASHOP}|g" /etc/templates/nginx.conf > /etc/nginx/nginx.conf
exit 0