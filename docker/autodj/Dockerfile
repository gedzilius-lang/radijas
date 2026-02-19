FROM python:3.11-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg wget && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY scheduler.py overlay.sh ./
RUN sed -i 's/\r$//' overlay.sh scheduler.py && chmod +x overlay.sh

CMD ["/app/overlay.sh"]
