FROM adonato/query-exporter:5.2.1@sha256:b89b7f21bb4a64d2156cc763d28b0f4c7f303754f0927072c5cc49bcb1d91306

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
