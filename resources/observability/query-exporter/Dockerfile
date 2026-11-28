FROM adonato/query-exporter:5.2.3@sha256:c8cb232170edfaa6892bcebb6f117dc5cbf5b5853ffdc13fcf0b2cb3d4f30740

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
