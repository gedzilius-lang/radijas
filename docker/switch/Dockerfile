FROM python:3.11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY switchd.py relay.py entrypoint.sh ./
RUN sed -i 's/\r$//' entrypoint.sh switchd.py relay.py && chmod +x entrypoint.sh

CMD ["/app/entrypoint.sh"]
