FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential cmake git curl wget \
    libssl-dev openssl libsqlite3-dev \
    zlib1g-dev pkg-config jq iproute2 python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/deps

# Install zlog
RUN git clone -b 1.2.15 https://github.com/HardySimpson/zlog.git && \
    cd zlog && make && make install && cd .. && rm -rf zlog

# Install jansson (neugates fork)
RUN git clone https://github.com/neugates/jansson.git && \
    cd jansson && mkdir build && cd build && \
    cmake -DJANSSON_BUILD_DOCS=OFF -DJANSSON_EXAMPLES=OFF .. && \
    make -j$(nproc) && make install && cd ../.. && rm -rf jansson

# Install mbedtls
RUN git clone -b v2.16.12 https://github.com/Mbed-TLS/mbedtls.git && \
    cd mbedtls && mkdir build && cd build && \
    cmake -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DENABLE_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON .. && \
    make -j$(nproc) && make install && cd ../.. && rm -rf mbedtls

# Install libjwt
RUN git clone -b v1.13.1 https://github.com/benmcollins/libjwt.git && \
    cd libjwt && mkdir build && cd build && \
    cmake -DENABLE_PIC=ON -DBUILD_SHARED_LIBS=OFF .. && \
    make -j$(nproc) && make install && cd ../.. && rm -rf libjwt

# Install protobuf-c
RUN apt-get update && apt-get install -y autoconf automake libtool protobuf-compiler libprotobuf-dev && \
    rm -rf /var/lib/apt/lists/* && \
    git clone -b v1.4.0 https://github.com/protobuf-c/protobuf-c.git && \
    cd protobuf-c && ./autogen.sh && \
    ./configure --disable-protoc --enable-shared=no CFLAGS=-fPIC CXXFLAGS=-fPIC && \
    make -j$(nproc) && make install && cd .. && rm -rf protobuf-c

# Install libxml2
RUN apt-get update && apt-get install -y python3-dev && rm -rf /var/lib/apt/lists/* && \
    git clone -b v2.9.14 https://github.com/GNOME/libxml2.git && \
    cd libxml2 && ./autogen.sh && \
    ./configure --enable-shared=no CFLAGS=-fPIC CXXFLAGS=-fPIC && \
    make -j$(nproc) && make install && cd .. && rm -rf libxml2

# Install googletest
RUN git clone -b release-1.11.0 https://github.com/google/googletest.git && \
    cd googletest && mkdir build && cd build && \
    cmake .. && make -j$(nproc) && make install && cd ../.. && rm -rf googletest

RUN ldconfig

# Copy NanoSDK source (with mock/probe instrumentation)
COPY NanoSDK /opt/NanoSDK

# Build NanoSDK
RUN cd /opt/NanoSDK && rm -rf build && mkdir build && cd build && \
    cmake -DBUILD_SHARED_LIBS=OFF -DNNG_TESTS=OFF \
        -DNNG_ENABLE_SQLITE=ON -DNNG_ENABLE_TLS=OFF .. && \
    make -j$(nproc) && make install && \
    ldconfig

# Copy neuron source
COPY neuron /opt/neuron

# Build neuron
RUN cd /opt/neuron && rm -rf build && mkdir build && cd build && \
    cmake -DDISABLE_WERROR=ON .. && \
    make -j$(nproc)

# Copy setup script
COPY setup_neuron.py /opt/setup_neuron.py

WORKDIR /opt/neuron/build

EXPOSE 7000

CMD ["./neuron", "--log"]
