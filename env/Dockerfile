# syntax=docker/dockerfile:1
#
# NAITAE evaluation image. Both JDKs are built from source at 21.0.10 so the only
# difference between them is the RV patches; the RV tool agents ship prebuilt.
#
#   /opt/jdk-native  modified RV JDK (bundled jdk21-4-rv/)
#   /opt/jdk-stock   stock openjdk/jdk21u @ jdk-21.0.10-ga, same configure flags
#   /opt/jdk8        Temurin 8, corpus compile fallback only (never on PATH/JAVA_HOME)
#
# Build from the repo root:  docker build -f env/Dockerfile -t naitae/rv-jdk21 .
# For a cluster:             apptainer build rv-jdk21.sif docker-daemon://naitae/rv-jdk21
FROM ubuntu:22.04

ARG UNMODIFIED_REPO=https://github.com/openjdk/jdk21u.git
ARG UNMODIFIED_TAG=jdk-21.0.10-ga

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates wget zip unzip locales locales-all \
      build-essential autoconf file \
      libx11-dev libxext-dev libxrender-dev libxrandr-dev libxtst-dev libxt-dev \
      libcups2-dev libfontconfig1-dev libasound2-dev libfreetype6-dev libffi-dev \
      libfreetype6 fontconfig libfontconfig1 \
      openjdk-21-jdk && \
    locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*
ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8

# Boot JDK for the two source builds only; not a comparison JDK.
ENV BOOT_JDK=/usr/lib/jvm/java-21-openjdk-amd64
ENV JAVA_HOME=${BOOT_JDK}

# Maven 3.9.x (needed for JDK21 + Sisu)
RUN wget -q https://archive.apache.org/dist/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.tar.gz && \
    tar -xzf apache-maven-3.9.6-bin.tar.gz -C /opt && rm apache-maven-3.9.6-bin.tar.gz && \
    ln -s /opt/apache-maven-3.9.6/bin/mvn /usr/local/bin/mvn

# JDK8 fallback for corpus projects that won't test-compile under JDK21.
RUN cd /opt && \
    wget -q https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u422-b05/OpenJDK8U-jdk_x64_linux_hotspot_8u422b05.tar.gz && \
    tar xf OpenJDK8U-jdk_x64_linux_hotspot_8u422b05.tar.gz && rm OpenJDK8U-jdk_x64_linux_hotspot_8u422b05.tar.gz && \
    mv jdk8u422-b05 jdk8 && /opt/jdk8/bin/javac -version

# AspectJ 1.9.21.2 (bumped heap for large weaves)
RUN cd /opt && wget -q https://github.com/eclipse-aspectj/aspectj/releases/download/V1_9_21_2/aspectj-1.9.21.2.jar && \
    mkdir -p /opt/aspectj && \
    ${BOOT_JDK}/bin/java -jar aspectj-1.9.21.2.jar -to /opt/aspectj && rm aspectj-1.9.21.2.jar && \
    sed -i 's/64M/10240M/g' /opt/aspectj/bin/ajc
ENV PATH=/opt/aspectj/bin:/usr/local/bin:${BOOT_JDK}/bin:/usr/bin:/bin
ENV CLASSPATH=/opt/aspectj/lib/aspectjtools.jar:/opt/aspectj/lib/aspectjrt.jar:/opt/aspectj/lib/aspectjweaver.jar

# async-profiler 2.9 (opt-in via ASYNC_PROFILER_LIB)
RUN cd /opt && wget -q https://github.com/async-profiler/async-profiler/releases/download/v2.9/async-profiler-2.9-linux-x64.tar.gz && \
    tar xf async-profiler-2.9-linux-x64.tar.gz && rm async-profiler-2.9-linux-x64.tar.gz && \
    mv async-profiler-2.9-linux-x64 async-profiler

# Modified JDK -> /opt/jdk-native
COPY jdk21-4-rv /opt/jdk-src
RUN cd /opt/jdk-src && rm -rf build && \
    bash configure --with-boot-jdk=${BOOT_JDK} --with-jvm-variants=server \
      --with-native-debug-symbols=none --disable-warnings-as-errors && \
    make images CONF=linux-x86_64-server-release && \
    cp -a build/linux-x86_64-server-release/images/jdk /opt/jdk-native && \
    cd / && rm -rf /opt/jdk-src && \
    /opt/jdk-native/bin/java --add-opens java.base/java.lang.rv=ALL-UNNAMED -version

# Stock JDK -> /opt/jdk-stock, same version and configure flags.
RUN git clone --depth 1 -b ${UNMODIFIED_TAG} ${UNMODIFIED_REPO} /opt/jdk-stock-src && \
    cd /opt/jdk-stock-src && \
    bash configure --with-boot-jdk=${BOOT_JDK} --with-jvm-variants=server \
      --with-native-debug-symbols=none --disable-warnings-as-errors && \
    make images CONF=linux-x86_64-server-release && \
    cp -a build/linux-x86_64-server-release/images/jdk /opt/jdk-stock && \
    cd / && rm -rf /opt/jdk-stock-src && /opt/jdk-stock/bin/java -version

# Prebuilt agents (JavaMOP/TraceMOP/Valg x stock/native) + javamop-extension.
# Native monitors reference java.lang.rv.* that only exists in the modified JDK, so
# the jars are codegen'd ahead of time and shipped in the repo (see env/agents/AGENTS.txt).
RUN mkdir -p /agents /extensions
COPY env/agents/javamop-stock.jar         /agents/javamop-stock.jar
COPY env/agents/javamop-native.jar        /agents/javamop-native.jar
COPY env/agents/javamop-stock-stats.jar   /agents/javamop-stock-stats.jar
COPY env/agents/javamop-native-stats.jar  /agents/javamop-native-stats.jar
COPY env/agents/valg-stock.jar            /agents/valg-stock.jar
COPY env/agents/valg-native.jar           /agents/valg-native.jar
COPY env/agents/valg-stock-stats.jar      /agents/valg-stock-stats.jar
COPY env/agents/valg-native-stats.jar     /agents/valg-native-stats.jar
COPY env/agents/lazymop-stock-gen.jar     /agents/lazymop-stock-gen.jar
COPY env/agents/lazymop-native-gen.jar    /agents/lazymop-native-gen.jar
COPY env/agents/javamop-extension-1.0.jar /extensions/javamop-extension-1.0.jar
COPY env/agents/tinymop-extension-1.0.jar /extensions/tinymop-extension-1.0.jar

# Runner scripts (corpus CSV is bind-mounted at run time, not baked).
COPY experiments/scripts/run-all.sh     /usr/local/bin/run-all.sh
COPY experiments/scripts/run-project.sh /usr/local/bin/run-project.sh
RUN chmod +x /usr/local/bin/run-all.sh /usr/local/bin/run-project.sh

# Default to the modified JDK; switch per run with JDK_HOME=${STOCK_JDK} MODES="baseline stock".
ENV NATIVE_JDK=/opt/jdk-native \
    STOCK_JDK=/opt/jdk-stock
ENV JAVA_HOME=/opt/jdk-native
ENV PATH=/opt/jdk-native/bin:/opt/aspectj/bin:/usr/local/bin:/usr/bin:/bin

# JavaMOP agents wired by default; -stats variants and STOCK_AGENT/NATIVE_AGENT swap them per run.
# Valg and LazyMOP agents are baked in too, so all tool cells run without host bind-mounts.
# LazyMOP additionally needs its Maven eventspy (tinymop-extension) via LAZYMOP_EXT to attach
# the agent + collect the trace DB the runner counts violations from.
ENV STOCK_AGENT=/agents/javamop-stock.jar \
    NATIVE_AGENT=/agents/javamop-native.jar \
    EXTENSION=/extensions/javamop-extension-1.0.jar \
    LAZYMOP_STOCK_AGENT=/agents/lazymop-stock-gen.jar \
    LAZYMOP_NATIVE_AGENT=/agents/lazymop-native-gen.jar \
    LAZYMOP_EXT=/extensions/tinymop-extension-1.0.jar \
    COMPILE_FALLBACK_JDK=/opt/jdk8 \
    CSV=/work/projects.csv \
    WORK=/work/out
WORKDIR /work
CMD ["/usr/local/bin/run-all.sh"]
