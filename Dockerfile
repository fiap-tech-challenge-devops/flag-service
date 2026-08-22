#Stage 1: Build
FROM python:3.9-alpine AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt

#Stage 2: Runtime
FROM python:3.9-alpine

RUN apk upgrade --no-cache && \
    apk add --no-cache wget

RUN addgroup -S togglemastergroup && adduser -S -u 10001 togglemaster -G togglemastergroup

WORKDIR /home/togglemaster

COPY --from=builder --chown=togglemaster:togglemastergroup /install /usr/local

COPY --chown=togglemaster:togglemastergroup app.py .

USER togglemaster

EXPOSE 8002

CMD ["gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
