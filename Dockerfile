# Production image for the Mojo and Co backend.
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Build deps for Pillow and psycopg2, removed again in the same layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev libjpeg-dev zlib1g-dev curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt requirements-prod.txt ./
RUN pip install --no-cache-dir -r requirements-prod.txt \
    && apt-get purge -y build-essential && apt-get autoremove -y

COPY . .

# collectstatic runs at build time so the image is ready to serve.
RUN DJANGO_DEBUG=False DJANGO_SECRET_KEY=build-only \
    python manage.py collectstatic --noinput

RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]

EXPOSE 8000

# Two workers is the right size for this box — it is shared with ten other
# projects and memory is the binding constraint, not CPU.
CMD ["gunicorn", "mojo_backend.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2", \
     "--timeout", "60", \
     "--access-logfile", "-"]
