# A stream from end to end: one VM runs Wolf as the rig does, a second one is
# a Moonlight client that pairs, starts two apps and shows what it receives.
#
#   nix build .#streamTest -L
#   xdg-open result/stream.png      # the client's screen: the test pattern
#   xdg-open result/menu.png        # the client's screen: the Wolf menu
#
# The two apps:
#   - a test pattern, drawn into Wolf's compositor by a process inside Wolf's
#     own container, checked by colour;
#   - "Wolf UI", the menu a player lands in: a session container Wolf starts
#     through Docker, checked by reading its title off the client's screen.
#
# What it can and cannot claim. The VMs have no GPU, so Wolf's compositor
# and the menu render in software and Wolf encodes with x264. Covered:
# pairing, the app list, RTSP, the firewall's port ranges, Wolf's compositor,
# a session container, encoding, FEC and RTP over a network link, and a real
# client decoding it. Not covered: VA-API, GPU rendering, audio (no
# PulseAudio container), input, and the game containers (Steam is a further
# image of several GB).
#
# The images are fetched by digest, because a test VM has no network and a
# moving tag is not reproducible. They are the images this was last run
# against, not necessarily what the tags (rig.wolf.image, and the Wolf UI
# entry in Wolf's config) point at today: move digest and hash together when
# Wolf is updated on the rig.
#   docker image inspect ghcr.io/games-on-whales/wolf:stable --format '{{.RepoDigests}}'
{ pkgs, lib, rigModules }:

let
  wolfImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/games-on-whales/wolf";
    imageDigest = "sha256:47ce7a0b67ee6645d2c6fefd8fdda7fee49a00e327c39597a04e84a0cd052910";
    finalImageName = "ghcr.io/games-on-whales/wolf";
    finalImageTag = "stable";
    hash = "sha256-UZRe1FDgEtITFSWedIIYUVxoTgNi3y8O2uk+LLtF9wk=";
  };

  uiImage = pkgs.dockerTools.pullImage {
    imageName = "ghcr.io/games-on-whales/wolf-ui";
    imageDigest = "sha256:cd6de1158b29068e4a4d4ce6312976067517239be97200a391be758a6ddfcf9b";
    finalImageName = "ghcr.io/games-on-whales/wolf-ui";
    finalImageTag = "main";
    hash = "sha256-EgMI4lIg7mlpaPL8rKXMcb5KVYrBL2fN/Lq5PcO0m9E=";
  };

  app = "Stream test";
  width = 1280;
  height = 720;

  # What the test adds to the config.toml Wolf writes on its first start.
  #
  # An app that draws SMPTE colour bars into Wolf's own compositor: the same
  # path a game's picture takes, without a session container to download.
  # (Wolf's own "Test ball" bypasses the compositor, and this Wolf ends such
  # a session after five seconds, waiting for a Wayland socket it never
  # made.)
  appToml = pkgs.writeText "stream-test-app.toml" ''
    [[profiles.apps]]
    title = '${app}'
    start_virtual_compositor = true
    start_audio_server = false

        [profiles.apps.runner]
        type = 'process'
        run_cmd = 'sh /etc/wolf/stream-test-app.sh'

        [profiles.apps.audio]
        source = 'audiotestsrc wave=silence is-live=true'
  '';
  # Runs inside Wolf's container (the state directory is /etc/wolf there).
  appScript = pkgs.writeText "stream-test-app.sh" ''
    exec gst-launch-1.0 videotestsrc pattern=smpte is-live=true \
      ! video/x-raw,width=${toString width},height=${toString height},framerate=30/1 ! waylandsink
  '';
  # Wolf's stock software encoder has no conversion step in front of it, and
  # the pipeline it then builds ("... ! ! x264enc") does not parse.
  x264Toml = pkgs.writeText "stream-test-x264.toml" ''
    video_params = 'videoconvertscale ! video/x-raw, chroma-site={color_range}, width={width}, height={height}, format=NV12, colorimetry={color_space}, pixel-aspect-ratio=1/1'
  '';
  # Also: the menu without its PulseAudio container, one image less.
  # Written for the file as Wolf first writes it.
  patchConfig = pkgs.writeShellScript "stream-test-config" ''
    set -eu
    toml=$1
    sed -i -E \
      -e "/^[[:space:]]*id = [\"']moonlight-profile-id[\"']/r ${appToml}" \
      -e "/plugin_name = [\"']x264[\"']/r ${x264Toml}" \
      -e "/title = [\"']Wolf UI[\"']/a start_audio_server = false" "$toml"
    grep -c "title = '${app}'" "$toml" | grep -qx 1
    grep -c "^video_params = 'videoconvertscale" "$toml" | grep -qx 1
  '';

  # bar N COLOUR: is the Nth of the seven colour bars on screen that colour?
  # Sampled a third of the way down, in the middle of the bar.
  bar = pkgs.writeShellScriptBin "bar" ''
    set -eu
    shot=$(mktemp --suffix=.png)
    trap 'rm -f "$shot"' EXIT
    import -silent -window root "$shot"
    read -r w h < <(magick identify -format '%w %h\n' "$shot")
    x=$(( ($1 * 2 + 1) * w / 14 - 10 )) y=$(( h / 3 ))
    rgb=$(magick "$shot" -crop "20x20+$x+$y" +repage -scale 1x1 -depth 8 txt:- \
      | grep -oE '\([0-9]+,[0-9]+,[0-9]+' | head -1 | tr -d '(')
    IFS=, read -r r g b <<<"$rgb"
    echo "bar $1 at $x,$y of ''${w}x$h is $r,$g,$b (want $2)" >&2
    hi=180 lo=75
    case $2 in
      yellow)  [ "$r" -gt $hi ] && [ "$g" -gt $hi ] && [ "$b" -lt $lo ] ;;
      green)   [ "$r" -lt $lo ] && [ "$g" -gt $hi ] && [ "$b" -lt $lo ] ;;
      red)     [ "$r" -gt $hi ] && [ "$g" -lt $lo ] && [ "$b" -lt $lo ] ;;
      blue)    [ "$r" -lt $lo ] && [ "$g" -lt $lo ] && [ "$b" -gt $hi ] ;;
      *) echo "bar: unknown colour $2" >&2; exit 2 ;;
    esac
  '';
in
pkgs.testers.nixosTest {
  name = "wolf-rig-stream";
  # For wait_for_text on the client's screen.
  enableOCR = true;

  nodes.server = { config, ... }: {
    imports = rigModules;
    rig.modules.streaming = true;
    rig.wolf = {
      # The test network, not the VM's NAT interface that holds the default
      # route: this is the address Wolf hands to clients for the stream.
      internalIp = config.networking.primaryIPAddress;
      # No GPU in a VM: Wolf's compositor renders with Mesa's software
      # rasteriser, and with no VA-API device Wolf picks x264 by itself.
      renderNode = "software";
      encoderNode = "none";
    };

    virtualisation.oci-containers.containers.wolf.imageFile = wolfImage;

    virtualisation = {
      # A render node for wolf-hw-detect to find.
      qemu.options = [ "-device virtio-gpu-pci" ];
      # The images are 4.5 and 1.7 GB unpacked, and Docker holds one twice
      # while loading it.
      diskSize = 24576;
      memorySize = 4096;
      cores = 4;
    };

    # What hosts/wolf-rig provides and the modules count on.
    networking.nftables.enable = true;
    users.users.ha.isNormalUser = true;
  };

  # A desktop, so that Moonlight has a screen to put the picture on and the
  # test can look at it.
  nodes.client = { ... }: {
    imports = [ "${pkgs.path}/nixos/tests/common/x11.nix" ];
    environment.systemPackages = [ pkgs.moonlight-embedded pkgs.imagemagick bar ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = { nodes, ... }: ''
    import json
    import re

    api = "curl -sS --fail --unix-socket /proc/$(docker inspect -f '{{.State.Pid}}' wolf)/root/run/user/wolf/wolf.sock http://localhost/api/v1"

    def wolf_is_up():
        # Loading the image into Docker is most of this.
        server.wait_for_unit("docker-wolf.service", timeout=1200)
        server.wait_for_open_port(47989, timeout=300)
        server.wait_until_succeeds(f"{api}/pair/pending", timeout=120)

    def stream(app, log):
        # SDL: Moonlight decodes the H.264 itself and draws it full screen.
        return (
            f"cd /root/stream && (SDL_AUDIODRIVER=dummy stdbuf -oL -eL moonlight stream -app '{app}' -platform sdl -codec h264 "
            "-mapping ${pkgs.moonlight-embedded}/share/moonlight/gamecontrollerdb.txt "
            f"-width ${toString width} -height ${toString height} -fps 30 -bitrate 5000 server > {log} 2>&1 &)"
        )

    start_all()

    with subtest("Wolf starts from the preloaded image and falls back to x264"):
        wolf_is_up()
        server.wait_until_succeeds("docker logs wolf 2>&1 | grep -q 'Using h264 encoder: x264'", timeout=60)

    with subtest("Wolf restarts with the test app in its config"):
        # Stopped first: Wolf writes its config back when it stops.
        server.succeed("systemctl stop docker-wolf.service")
        server.succeed("${patchConfig} ${nodes.server.rig.wolf.stateDir}/cfg/config.toml")
        server.succeed("cp ${appScript} ${nodes.server.rig.wolf.stateDir}/stream-test-app.sh")
        server.succeed("docker load -i ${uiImage}")
        server.succeed("systemctl start docker-wolf.service")
        wolf_is_up()

    with subtest("a Moonlight client pairs, the PIN answered through Wolf's API"):
        client.wait_for_x()
        client.succeed("mkdir -p /root/stream")
        client.succeed("cd /root/stream && (moonlight pair server > pair.log 2>&1 &)")
        client.wait_until_succeeds("grep -Eq 'PIN.*[0-9]{4}' /root/stream/pair.log", timeout=120)
        pin = re.findall(r"\b\d{4}\b", client.succeed("grep -E 'PIN.*[0-9]{4}' /root/stream/pair.log"))[0]
        pending = json.loads(server.wait_until_succeeds(f"{api}/pair/pending | grep pair_secret", timeout=60))
        body = json.dumps({"pair_secret": pending["requests"][0]["pair_secret"], "pin": pin})
        server.succeed(f"{api}/pair/client -X POST -H 'Content-Type: application/json' -d '{body}'")
        client.wait_until_succeeds("grep -qi 'paired' /root/stream/pair.log", timeout=60)

    with subtest("the paired client sees the app list"):
        apps = client.succeed("moonlight list server 2>&1")
        assert "${app}" in apps, apps

    with subtest("the client shows the picture Wolf's compositor rendered"):
        client.succeed(stream("${app}", "stream.log"))
        try:
            # SMPTE bars, left to right: white, yellow, cyan, green, magenta,
            # red, blue.
            client.wait_until_succeeds("bar 1 yellow && bar 3 green && bar 5 red && bar 6 blue", timeout=120)
        finally:
            client.screenshot("stream")
            print(client.succeed("cat /root/stream/stream.log"))
            print(server.succeed("docker logs wolf 2>&1 | tail -n 40"))

    with subtest("Wolf has the session, at the size the client asked for"):
        sessions = json.loads(server.succeed(f"{api}/sessions"))["sessions"]
        assert len(sessions) == 1, sessions
        assert (sessions[0]["video_width"], sessions[0]["video_height"]) == (${toString width}, ${toString height}), sessions

    with subtest("the Wolf menu: its session container starts and the client shows it"):
        client.succeed("pkill moonlight; sleep 3; moonlight quit server")
        client.succeed(stream("Wolf UI", "menu.log"))
        # The container name is what rig-gaming-guard watches for.
        server.wait_until_succeeds("docker ps --format '{{.Names}}' | grep -q '^Wolf-UI_'", timeout=120)
        try:
            # Read off the client's screen: the profile picker's title.
            client.wait_for_text("Select User", timeout=300)
        finally:
            client.screenshot("menu")
            print(client.succeed("cat /root/stream/menu.log"))
            print(server.succeed("docker logs wolf 2>&1 | tail -n 40; docker ps -a"))
  '';
}
