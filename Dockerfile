FROM kong/kong:e17e3dbc6ef6314c7d22c4dc4a8e82dd6be35711-ubuntu

COPY lua-resty-protobuf /tmp/lua-resty-protobuf
COPY --chown=root:root --chmod=744  docker-entrypoint.sh /entrypoint.sh

USER root:root
RUN apt-get update -y \
    && apt-get install -y \
            automake \
            build-essential \
            libprotobuf-dev \
            protobuf-compiler \
            libabsl-dev \
    && echo "Successfully installed protobuf" \
    && cd /tmp/lua-resty-protobuf \
    && make install \
    && gcc -O2 -g3 consumer.c -o /usr/local/bin/consumer \
    && echo "Successfully installed lua-resty-protobuf"

USER kong:kong
