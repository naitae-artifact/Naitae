FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    build-essential autoconf zip unzip \
    libx11-dev libxext-dev libxrender-dev libxrandr-dev libxtst-dev libxt-dev \
    libcups2-dev libfontconfig1-dev libasound2-dev \
    libfreetype-dev libharfbuzz-dev \
    openjdk-21-jdk \
    && rm -rf /var/lib/apt/lists/*

COPY . /build/jdk21-rv
WORKDIR /build/jdk21-rv

RUN bash configure --with-boot-jdk=/usr/lib/jvm/java-21-openjdk-amd64 \
    --disable-warnings-as-errors \
    --with-debug-level=release \
    && make images JOBS=$(nproc)

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y libfreetype6 libfontconfig1 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/jdk21-rv/build/linux-x86_64-server-release/jdk /opt/jdk21-rv

ENV JAVA_HOME=/opt/jdk21-rv
ENV PATH="$JAVA_HOME/bin:$PATH"

ENTRYPOINT ["java"]
