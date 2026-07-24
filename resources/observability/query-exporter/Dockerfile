FROM adonato/query-exporter:5.2.0@sha256:75a854f9803539f04224f9eda825f4956bc3212fefb9883b3fae488b5decc5ec

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
