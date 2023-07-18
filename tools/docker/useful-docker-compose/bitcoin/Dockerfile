FROM debian
WORKDIR /app

COPY ./bitcoin-22.0-x86_64-linux-gnu.tar.gz /app
COPY ./bitcoin.conf /app/bitcoin.conf
RUN mkdir /app/datadir
RUN tar -xzf bitcoin-22*.tar.gz && rm -rf bitcoin-22*.tar.gz

# rpc
EXPOSE 8838
# p2p
EXPOSE 8890

CMD ["/app/bitcoin-22.0/bin/bitcoind","-datadir=/app/datadir","-conf=/app/bitcoin.conf"]

