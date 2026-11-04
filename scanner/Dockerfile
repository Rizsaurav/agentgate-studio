# The security scanner service (LLM Guard). Reachable only on the compose network.
# Pinned by digest (same bytes for everyone); Dependabot proposes updates.
FROM python:3.11-slim-bookworm@sha256:94a8fee35252d06ab75856f15f12c7bae67b10e8a6da93c7fded82b2610926cd

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/home/scanner/.cache/huggingface \
    AGENTGATE_SCANNER_HOST=0.0.0.0
RUN useradd --create-home --uid 1000 scanner \
 && mkdir -p /home/scanner/.cache/huggingface \
 && chown -R scanner:scanner /home/scanner/.cache
WORKDIR /srv

COPY requirements.txt .
# The CPU build of PyTorch: the default Linux wheel pulls several GB of GPU libraries.
RUN pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt
COPY server.py .

USER scanner
EXPOSE 8765
# The first start downloads the model (about 700 MB) into the cache volume.
HEALTHCHECK --interval=10s --timeout=5s --start-period=600s --retries=5 \
  CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8765/health', timeout=3)"
CMD ["python", "server.py"]
