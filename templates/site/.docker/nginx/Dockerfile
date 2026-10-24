FROM nginx:alpine

# 99-change.sh génère /etc/nginx/nginx.conf depuis le modèle monté (/etc/templates/nginx.conf).
COPY 99-change.sh /docker-entrypoint.d/
RUN chmod 755 /docker-entrypoint.d/99-change.sh

WORKDIR /var/www
CMD ["nginx"]
