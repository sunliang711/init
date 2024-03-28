FROM rust:1.74.0-alpine as builder
# CN
# RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.ustc.edu.cn/g' /etc/apk/repositories

RUN apk add --no-cache musl-dev openssl-dev openssl-libs-static pkgconf make protoc git
WORKDIR /usr/src/app
COPY . .
RUN make build

FROM scratch
WORKDIR /usr/local/bin
COPY --from=builder /usr/src/app/target/release/rust_tmpl app
CMD [ "app" ]

# docker build --build-arg HTTP_PROXY=http://<HOST>:<PORT> --build-arg HTTP_PROXY=http://<HOST>:<PORT> -t <TAG> .
