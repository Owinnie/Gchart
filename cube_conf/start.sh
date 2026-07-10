#!/bin/sh
# Prepare container-local Cube conf, then start the server.
#
# Dynamic `public: check_visibility(...)` injection must NEVER touch the git
# checkout. When compose bind-mounts the repo, it is mounted read-only at
# CUBE_CONF_SRC (/cube/conf.src). We sync into /cube/conf (image-local,
# writable) and run generate_access_rules.py only there.
set -e

CUBE_CONF_SRC="${CUBE_CONF_SRC:-/cube/conf.src}"
CUBE_CONF_DST="${CUBE_CONF_DST:-/cube/conf}"

sync_conf_from_src() {
  if [ ! -d "${CUBE_CONF_SRC}" ]; then
    return 0
  fi

  echo "Syncing Cube conf from ${CUBE_CONF_SRC} -> ${CUBE_CONF_DST} (container-local)"
  # Replace destination contents without writing back through the bind mount.
  find "${CUBE_CONF_DST}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  cp -a "${CUBE_CONF_SRC}/." "${CUBE_CONF_DST}/"
}

sync_conf_from_src

cd "${CUBE_CONF_DST}"

if [ -f ./.env ]; then
  set -o allexport
  # shellcheck disable=SC1091
  . ./.env
  set +o allexport
elif [ -f /cube/.env ]; then
  set -o allexport
  # shellcheck disable=SC1091
  . /cube/.env
  set +o allexport
fi

# Injection is opt-in via env so a bare local `python generate_access_rules.py`
# cannot rewrite model YAML in the repo. Docker build + this entrypoint set it.
if [ "${SKIP_GENERATE_ACCESS_RULES:-0}" != "1" ]; then
  export CUBE_INJECT_VISIBILITY="${CUBE_INJECT_VISIBILITY:-1}"
  echo "Generating access rules (CUBE_INJECT_VISIBILITY=${CUBE_INJECT_VISIBILITY})"
  python3 python/generate_access_rules.py
fi

exec "$@"
