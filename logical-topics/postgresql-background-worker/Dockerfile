FROM postgres:11
WORKDIR /
RUN apt update && apt install -y build-essential git postgresql-server-dev-11 libssl-dev libkrb5-dev && git clone https://github.com/vibhorkum/pg_background.git && cd pg_background && make && make install && apt remove -y build-essential git postgresql-server-dev-11 libssl-dev libkrb5-dev && apt-get clean autoclean && apt-get autoremove --yes && rm -rf /var/lib/{apt,dpkg,cache,log}/
