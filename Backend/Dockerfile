FROM python:3.14-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN groupadd --system kingdomkids \
    && useradd --system --gid kingdomkids --home-dir /app kingdomkids

COPY requirements.txt ./requirements.txt
RUN python -m pip install --requirement requirements.txt

COPY Core ./Core
COPY scripts ./scripts
COPY content/releases/character_narration_v1_manifest.json ./content/releases/character_narration_v1_manifest.json
COPY content/releases/cloudinary_first_release_v1.json ./content/releases/cloudinary_first_release_v1.json

# Static assets contain only application/admin resources and require no
# production secret or network dependency at image-build time.
RUN DJANGO_DEBUG=true python Core/manage.py collectstatic --noinput \
    && chmod -R a-w /app

USER kingdomkids

EXPOSE 8000

CMD ["gunicorn", "--chdir", "Core", "Core.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "30", "--graceful-timeout", "30", "--access-logfile", "-", "--error-logfile", "-"]
