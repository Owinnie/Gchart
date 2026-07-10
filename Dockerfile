# Official Cube.js image + Lecturio access-rule generation at build time.
# Visibility-flag injection lands only in the image filesystem — never in git.
FROM cubejs/cube:v1.3.77

USER root

COPY ./cube_conf/requirements.txt /cube/conf/requirements.txt

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3-pip && \
    pip3 install --upgrade --break-system-packages pip && \
    pip3 install --break-system-packages -r /cube/conf/requirements.txt && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Conf is copied into the image; generate/inject here so production images are
# ready even when start.sh skips regeneration.
COPY ./cube_conf /cube/conf

WORKDIR /cube/conf
RUN chmod +x /cube/conf/start.sh && \
    CUBE_INJECT_VISIBILITY=1 python3 python/generate_access_rules.py

# Do not bake secrets into the image. Pass env at runtime (compose env_file /
# orchestrator secrets). Optional /cube/.env is supported by the wrapper if you
# mount one.
RUN printf '%s\n' \
  '#!/bin/sh' \
  'set -e' \
  'if [ -f /cube/.env ]; then' \
  '  set -o allexport' \
  '  # shellcheck disable=SC1091' \
  '  . /cube/.env' \
  '  set +o allexport' \
  'fi' \
  'exec /cube/conf/start.sh "$@"' \
  > /usr/local/bin/entrypoint-wrapper.sh && \
  chmod +x /usr/local/bin/entrypoint-wrapper.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]
CMD ["cubejs", "server"]
