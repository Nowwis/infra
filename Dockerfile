FROM alpine:latest

WORKDIR /app

# Installer Docker CLI, Docker Compose, Make, Bash
RUN apk add --no-cache \
    docker-cli \
    docker-compose \
    make \
    bash \
    curl

COPY . .

CMD ["sh", "-c", "make up && tail -f /dev/null"]