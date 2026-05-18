FROM adonato/query-exporter:5.0.2@sha256:b1cca5a315160fd9023eebe32391bf7d551d3e6af02eb7ed7ec4e11359835c43

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
