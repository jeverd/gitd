# gitd in a container: built with Zig 0.17.1, run with git and sqlite.
#
#   docker build -t gitd .
#   docker run -v gitd-data:/data -p 8080:8080 gitd
#
# The server listens on 0.0.0.0:8080 and keeps everything in /data. The admin key is
# GITD_ADMIN_KEY when set (make one with `gitd admin create-key`); otherwise the first start
# makes one and writes it to /data/admin-key (mode 0600). See docker/entrypoint.sh.
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.17.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libsqlite3-dev libgit2-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN arch="$(uname -m)" \
    && tarball="zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
    && for base in \
        https://ziglang.freetls.fastly.net \
        https://zig.chainsafe.dev \
        https://pkg.hexops.org/zig \
        https://zigmirror.hryx.net/zig \
        "https://ziglang.org/download/${ZIG_VERSION}"; do \
        curl -fsSL --connect-timeout 10 --max-time 90 "${base}/${tarball}" -o /tmp/zig.tar.xz && break; \
      done \
    && mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN /opt/zig/zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git libsqlite3-0 libgit2-1.5 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home-dir /data gitd && mkdir /data && chown gitd /data
COPY --from=build /src/zig-out/bin/gitd /usr/local/bin/gitd
COPY docker/entrypoint.sh /usr/local/bin/gitd-entrypoint
USER gitd
VOLUME /data
EXPOSE 8080
ENV GITD_DATA=/data GITD_LISTEN=0.0.0.0:8080
HEALTHCHECK --interval=2s --timeout=3s --retries=15 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /healthz HTTP/1.0\\r\\n\\r\\n' >&3 && head -1 <&3 | grep -q ' 200 '"]
ENTRYPOINT ["gitd-entrypoint"]
CMD ["gitd", "serve"]
