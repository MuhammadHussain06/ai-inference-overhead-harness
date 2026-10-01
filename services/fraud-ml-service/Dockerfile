FROM python:3.11-slim@sha256:e41613d42d4891e4930f79523f93f81bbc7632584ec65e36ab055f41a800b41e
WORKDIR /app

# Installs the locked environment (direct and transitive pins) so rebuilds match the measured image.
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock

COPY app/ ./app/
COPY models/ ./models/

EXPOSE 8000
ENV UVICORN_WORKERS=1

ENV OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1
# --no-access-log: uvicorn logs every request to stdout by default, synchronously,
# on the request-handling coroutine -- disabled to keep it off the measured path.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${UVICORN_WORKERS} --no-access-log"]