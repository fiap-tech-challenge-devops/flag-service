# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM python:3.9-alpine AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt


FROM python:3.9-alpine


RUN apk --no-cache add wget


RUN addgroup -S appgroup && adduser -S -u 10001 appuser -G appgroup

WORKDIR /home/appuser


COPY --from=builder --chown=appuser:appgroup /install /usr/local


COPY --chown=appuser:appgroup app.py .

USER appuser

EXPOSE 8002

CMD ["gunicorn", "--bind", "0.0.0.0:8002", "app:app"]
