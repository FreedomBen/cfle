FROM almalinux:8.4

#
# almalinux was used as a base image here instead of the Red Hat UBI image because
# some of the packages needed were not in the UBI repos.  If a user has a RHEL
# subscription, it should be drop in replacement to switch to a RHEL base for a fully
# supported configuration
#

ENV USER_HOME /home/docker
ENV LANG en_US.UTF-8
ENV KUBECTL_VER=v1.20.5

# Create non-root user
RUN groupadd --gid 1000 docker \
 && adduser --uid 1000 --gid 1000 --home ${USER_HOME} docker \
 && usermod -L docker

# Install EPEL, base packages, and app dependencies
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm \
 && dnf install -y https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm \
 && dnf install -y https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-8.noarch.rpm \
 && dnf install -y epel-release \
 && dnf install -y \
    glibc-langpack-en \
    dnf-plugins-core \
 && dnf config-manager --set-enabled powertools \
 && dnf update -y \
 && dnf install -y \
    openssl \
    curl \
    jq \
    certbot \
    python3-certbot-dns-cloudflare \
    python-certbot-dns-cloudflare-doc \
 && dnf module install -y ruby:2.7 \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/yum

# Install Kubectl
RUN cd /tmp \
 && curl -LO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl" \
 && curl -LO "https://dl.k8s.io/${KUBECTL_VER}/bin/linux/amd64/kubectl.sha256" \
 && echo "$(<kubectl.sha256) kubectl" | sha256sum --check \
 && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
 && rm -rf /tmp/*

# Copy app source
RUN mkdir -p /app \
 && chown -R docker:docker /app

WORKDIR /app

# Unfortuantely composer install depends on some app code so we have to copy
# it all in and run composer install every time
COPY --chown=docker:docker . /app/

CMD /app/renew.sh
