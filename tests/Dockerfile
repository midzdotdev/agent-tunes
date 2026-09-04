# Runs the silent suites on Linux. Two things this buys over the host: a machine
# with no audio hardware whatsoever, and proof that none of this quietly depends
# on macOS.
#
# mpv and ffmpeg are here for tests/integration.sh, which drives the real player
# through its null audio output. The CoreAudio checker cannot run here at all,
# which is exactly why it is stubbed and covered separately on a real Mac.
FROM debian:stable-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash python3 findutils gawk procps mpv ffmpeg \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
COPY . /repo
CMD ["bash", "-c", "tests/unit.sh && tests/integration.sh"]
