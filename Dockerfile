# multi-stage build for dockerized nginx

# set up nginx build container
FROM debian:stable-slim AS nginx

# allow multiarch builds
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT=""

# install dependencies
RUN apt-get update \
    && apt-get install -y \
        curl \
        g++ \
        gcc \
        git \
        make \
        perl \
        tar \
        upx

# download pcre library
WORKDIR /src/pcre
ARG PCRE_VER=8.45
RUN curl -L -O "https://cfhcable.dl.sourceforge.net/project/pcre/pcre/${PCRE_VER}/pcre-${PCRE_VER}.tar.gz" \
    && tar xzf "/src/pcre/pcre-${PCRE_VER}.tar.gz"

# download openssl
ARG OPENSSL_VER=openssl-3.0.5
WORKDIR /src/openssl
RUN git clone -b "${OPENSSL_VER}" git://git.openssl.org/openssl.git /src/openssl
ARG CORE_COUNT=1
RUN ./config && make -j"${CORE_COUNT}"

# download zlib
WORKDIR /src/zlib
ARG ZLIB_VER=1.2.12
RUN curl -L -O "https://www.zlib.net/zlib-${ZLIB_VER}.tar.gz" \
    && tar xzf "zlib-${ZLIB_VER}.tar.gz"

# download brotli module
WORKDIR /src/ngx_brotli
RUN git clone https://github.com/google/ngx_brotli.git /src/ngx_brotli \
    && git submodule update --init

# download fancy-index module
RUN git clone https://github.com/aperezdc/ngx-fancyindex.git /src/ngx-fancyindex

# download nginx source
WORKDIR /src/nginx
ARG NGINX_VER = $(curl -s https://nginx.org/en/download.html | grep -oP 'nginx-[0-9.]+.tar.gz' | head -n 1 | cut -d'-' -f2 | cut -d'.' -f1-3)
RUN curl -L -O "http://nginx.org/download/nginx-${NGINX_VER}.tar.gz" \
    && tar xzf "nginx-${NGINX_VER}.tar.gz"

# configure and build nginx
WORKDIR /src/nginx/nginx-"${NGINX_VER}"
RUN ./configure --prefix=/usr/share/nginx \
                --sbin-path=/usr/sbin/nginx \
                --conf-path=/etc/nginx/nginx.conf \
                --error-log-path=/var/log/nginx/error.log \
                --http-log-path=/var/log/nginx/access.log \
                --pid-path=/tmp/nginx.pid \
                --lock-path=/run/lock/subsys/nginx \
                --http-client-body-temp-path=/tmp/nginx/client \
                --http-proxy-temp-path=/tmp/nginx/proxy \
                --with-threads \
                --with-file-aio \
                --with-zlib="/src/zlib/zlib-${ZLIB_VER}" \
                --with-pcre="/src/pcre/pcre-${PCRE_VER}" \
                --with-pcre-jit \
                --with-http_addition_module \
                --with-http_random_index_module \
                --with-http_ssl_module \
                --with-http_stub_status_module \
                --with-http_sub_module \
                --add-module=/src/ngx_brotli \
                --add-module=/src/ngx-fancyindex \
                --with-openssl=/src/openssl \
                --without-http_uwsgi_module \
                --without-http_scgi_module \
                --without-select_module \
                --without-poll_module \
                --without-mail_pop3_module \
                --without-mail_imap_module \
                --without-mail_smtp_module \
                --with-cc-opt="-O2 -flto -ffunction-sections -fdata-sections -fPIE -fstack-protector-all -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
                --with-ld-opt="-Wl,--gc-sections -s -static -static-libgcc" \
    && make -j $(nproc) \
    && make install

# compress the nginx binary
RUN upx --best /usr/sbin/nginx

# setup nginx folders and files
RUN mkdir -p /etc/nginx \
    && mkdir -p /tmp/nginx/{client,proxy} \
    && mkdir -p /usr/share/nginx/fastcgi_temp \
    && mkdir -p /var/log/nginx \
    && mkdir -p /var/www/html \
    && touch /tmp/nginx.pid

# copy in default nginx configs
COPY nginx/ /etc/nginx/

# set up the final container
FROM gcr.io/distroless/static:nonroot

# run as nonroot
USER nonroot

# copy files over
COPY --from=nginx --chown=nonroot:nonroot /etc/nginx /etc/nginx
COPY --from=nginx --chown=nonroot:nonroot /tmp/nginx.pid /tmp/nginx.pid
COPY --from=nginx --chown=nonroot:nonroot /tmp/nginx /tmp/nginx
COPY --from=nginx --chown=nonroot:nonroot /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx --chown=nonroot:nonroot /usr/share/nginx/fastcgi_temp /usr/share/nginx/fastcgi_temp
COPY --from=nginx --chown=nonroot:nonroot /var/log/nginx /var/log/nginx
COPY --from=nginx --chown=nonroot:nonroot /var/www/html /var/www/html
COPY --chown=nonroot:nonroot html/index.html /var/www/html/index.html

# listen on an unprivileged port
EXPOSE 8080

# configure entrypoint
ENTRYPOINT ["/usr/sbin/nginx","-g","daemon off;"]
