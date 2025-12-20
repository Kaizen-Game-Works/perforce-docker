ARG HELIX_P4D_VERSION=2025.2
ARG HELIX_SWARM_VERSION=2025.4

FROM ubuntu:24.04 AS helix-base

RUN echo "P4D Dockerfile Start"
RUN echo "Beginning apt-get update"

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
 && DEBIAN_FRONTEND=noninteractive apt-get -y install \
        curl \
        gosu \
        software-properties-common \
        vim-tiny \
        nano \
 && update-alternatives --install /usr/bin/editor editor /usr/bin/vi 1000 \
 && rm -rf /var/lib/apt/lists/*

RUN echo "apt-get update complete"

# Added by Kaizen to ensure we have consistent UIDs

# make sure we have a home dir for user perforce
RUN echo "creating home directory for perforce user"
RUN mkdir -p /opt/perforce && chown 101:102 /opt/perforce

# Create the "perforce" group first
RUN echo "create the perforce group"
RUN groupadd --gid 102 perforce

# Then create the user with attributes
RUN echo "creating the perforce user and assigning groups & home directory"

RUN useradd \
    --uid 101 \
    --gid 102 \
    --create-home \
    --home-dir /opt/perforce \
    --shell /bin/bash \
    -c "P4 Admin" \
    perforce

# Set permissions
RUN echo "Setting permissions for data and home directories"
RUN mkdir -p /data && chown -R 101:102 /data
RUN chown -R 101:102 /opt/perforce

#end added by Kaizen

ARG HELIX_P4D_VERSION
ENV HELIX_P4D_VERSION=${HELIX_P4D_VERSION}
ARG HELIX_SWARM_VERSION
ENV HELIX_SWARM_VERSION=${HELIX_SWARM_VERSION}

RUN echo "Grabbing perforce"
RUN curl -s -L https://package.perforce.com/perforce.pubkey | gpg --dearmor > /etc/apt/trusted.gpg.d/perforce.gpg \
 && apt-add-repository -y "deb http://package.perforce.com/apt/ubuntu $(lsb_release -sc) release" \
 && rm -rf /var/lib/apt/lists/*


FROM helix-base AS helix-p4d

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive \
    apt-get -y install \
        helix-p4d="${HELIX_P4D_VERSION}"-* \
        helix-swarm-triggers="${HELIX_SWARM_VERSION}"-* \
 && rm -rf /var/lib/apt/lists/*

# Added by Kaizen to install apps needed for backup processors
# We so this here to prevent clases with users and group id's which occur if
# openssh-client is installed earlier in the process

# Install rsync - doing this as it's own step just to keep it clear what's been added
# over the original maintainer
RUN echo "Grabbing rsync"
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive \
    apt-get -y install rsync openssh-client \
 && rm -rf /var/lib/apt/lists/*

#end added by Kaizen

RUN echo "Setting up environment variables"
ENV P4PORT=ssl:1666
ENV P4USER=p4admin
ENV P4PASSWD=P@ssw0rd

ENV P4NAME=master
ENV P4ROOT=/data/${P4NAME}/root
ENV P4SSLDIR=${P4ROOT}/ssl

RUN echo "Copying files"
COPY docker-entrypoint.sh /
COPY docker-startup.d/    /docker-startup.d/
COPY p4-depots            /p4-depots
COPY p4-groups            /p4-groups
COPY p4-passwd            /p4-passwd
COPY p4-protect           /p4-protect
COPY p4-typemap           /p4-typemap
COPY p4-users             /p4-users

HEALTHCHECK --interval=1m --timeout=5s --start-period=30s \
    CMD p4 info

RUN echo "Running entrypoint scripts"
SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/docker-entrypoint.sh"]
# Using shell-form is required for ${P4PORT} to be correctly resolved (not working in JSON format).
CMD gosu perforce p4d -p "${P4PORT}"

RUN echo "P4D Dockerfile complete"

