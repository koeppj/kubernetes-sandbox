FROM debian:12.11-slim@sha256:b1a741487078b369e78119849663d7f1a5341ef2768798f7b7406c4240f86aef

ARG AWSCLI_VERSION=2.27.37
ARG KUBECTL_VERSION=v1.33.3
ARG BUILDKIT_VERSION=v0.26.2
ARG TARGETARCH=amd64
ARG AWSCLI_ARCH=x86_64

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates=20250419~deb12u1 \
      git=1:2.39.5-0+deb12u3 \
      unzip=6.0-28+deb12u1 \
      wget=1.21.3-1+deb12u1 \
    && wget -q "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}-${AWSCLI_VERSION}.zip" -O /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && wget -q "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -O /usr/local/bin/kubectl \
    && chmod 0755 /usr/local/bin/kubectl \
    && wget -q "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${TARGETARCH}.tar.gz" -O /tmp/buildkit.tar.gz \
    && tar -xzf /tmp/buildkit.tar.gz -C /tmp \
    && install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl \
    && rm -rf /tmp/aws /tmp/awscliv2.zip /tmp/buildkit.tar.gz /tmp/bin /var/lib/apt/lists/*

USER 1000:1000
WORKDIR /home/jenkins/agent
