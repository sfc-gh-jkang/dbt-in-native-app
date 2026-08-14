# dbt Core runtime for Snowpark Container Services.
#
# IP NOTE: the dbt project -- models, macros, Jinja, dbt_packages -- is baked
# into this image. The image lives in the PROVIDER's image repository and is
# bundled into the application package. Consumers can neither pull nor inspect
# it, so no raw Jinja or macro source ever lands in the consumer account.
#
# Must be built for linux/amd64 (SPCS runs amd64; build host here is arm64):
#   docker buildx build --platform linux/amd64 --push -t <repo>/<image>:<tag> .

FROM --platform=linux/amd64 python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DBT_SEND_ANONYMOUS_USAGE_STATS=0

# coreutils gives us `shred` for token cleanup; git is needed if dbt deps are
# ever resolved from a git ref at build time.
RUN apt-get update \
 && apt-get install -y --no-install-recommends coreutils git \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      "dbt-core>=1.9,<2.0" \
      "dbt-snowflake>=1.9,<2.0"

WORKDIR /app

# Project files -- this is the intellectual property.
COPY dbt_project/ /app/dbt_project/

# Resolve dbt packages at BUILD time so the container needs no egress (and
# therefore no External Access Integration) at run time.
RUN if [ -f /app/dbt_project/packages.yml ]; then \
      cd /app/dbt_project && dbt deps --profiles-dir /tmp || true ; \
    fi

COPY entrypoint.sh /app/entrypoint.sh
COPY token_probe.py /app/token_probe.py
RUN chmod +x /app/entrypoint.sh

# Fail fast at build time if dbt is not importable.
RUN dbt --version

ENTRYPOINT ["/app/entrypoint.sh"]
