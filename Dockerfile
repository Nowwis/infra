FROM docker/compose:alpine

WORKDIR /app

COPY . .

CMD ["sh", "-c", "make up && tail -f /dev/null"]