FROM openresty/openresty:1.27.1.2-0-alpine

RUN apk add --no-cache curl perl
RUN opm get openresty/lua-resty-redis
RUN opm get ledgetech/lua-resty-http

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua /usr/local/openresty/nginx/lua
