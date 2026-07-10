# GChart

- Real time chat application using:
    * Django
    * Tailwind

## Cube conf: Docker-only visibility injection

See [`cube_conf/README.md`](cube_conf/README.md). Dynamic `public: check_visibility(...)` flags are injected only inside the image/container (`Dockerfile` + `start.sh` with a read-only `/cube/conf.src` mount), so local `git status` stays clean.
