# Python backend (Flask + Gunicorn)
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# System deps for psycopg / build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

COPY workers-py/requirements.txt ./requirements.txt
RUN pip install --upgrade pip \
 && pip install -r requirements.txt

COPY workers-py/ .

# Gunicorn binds to 0.0.0.0:5000 inside container
ENV PORT=5000
EXPOSE 5000

CMD ["gunicorn", "-c", "gunicorn.conf.py", "application:application"]


