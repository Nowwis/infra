FROM nginx:alpine

# 99-change.sh génère /etc/nginx/nginx.conf depuis le modèle monté (/etc/templates/nginx.conf).
COPY 99-change.sh /docker-entrypoint.d/
RUN chmod 755 /docker-entrypoint.d/99-change.sh

# Point d'extension du projet : chaque config de type inclut /etc/nginx/project.d/*.conf dans son bloc server.
RUN mkdir -p /etc/nginx/project.d

WORKDIR /var/www
CMD ["nginx"]
