# Runs the silent suite on Linux. Two things this buys over running it on the
# host: a machine with no audio hardware at all, and proof that the orchestration
# layer has no hidden dependency on macOS. The CoreAudio checker and the real
# player cannot run here, which is exactly why they are stubbed.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash python3 findutils gawk procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
COPY . /repo
CMD ["bash", "tests/unit.sh"]
