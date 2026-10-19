{ config, pkgs, lib, ... }:

{
  imports = [ ./rig.nix ./disks.nix ];

  # ---------------------------------------------------------------------------
  # Boot / kernel
  # ---------------------------------------------------------------------------
  boot.loader.systemd-boot = {
    enable = true;
    # Bounded, because /boot is a 1 GiB vfat and each generation costs a
    # kernel plus a large initrd. Ten is enough history to roll back through a
    # bad week and few enough to never fill the ESP.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Not the LTS default, and this is a hardware requirement rather than a
  # preference. The discrete GPU in this box is Navi 48 (RX 9070 XT, PCI ID
  # 1002:7550), which amdgpu only gained support for in 6.13, and the CPU is a
  # Zen 5 part whose amd-pstate and temperature sensors also want a recent
  # kernel. On an older kernel the card either does not bind at all or binds
  # without the video engine -- and no render node means Wolf has nothing to
  # encode with.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The RX 9070 needs its firmware blobs loaded before it will bring up the
  # display and video engines at all.
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" "uas"
  ];

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------
  # A fixed name, unlike the parent flake's machine-id-derived miner-<id>.
  # That scheme exists so one image can install many interchangeable rigs; this
  # is one specific machine with a fixed address and a Moonlight client list
  # that finds it by name, so a stable hostname is worth more here than a
  # collision-proof one. It also becomes the XMRig worker name.
  networking.hostName = "wolf-rig";
  networking.useDHCP = lib.mkDefault true;
  networking.networkmanager.enable = false;

  # Required by modules/mining.nix and modules/wolf.nix: mining.nix opens its
  # LAN-only port with `networking.firewall.extraInputRules`, which only the
  # nftables backend applies. Under the default iptables backend that rule is
  # silently ignored and the default-deny policy blocks Home Assistant from
  # the XMRig API.
  networking.nftables.enable = true;

  # DNS over TLS, for the reasons documented at length in the parent flake:
  # filtering resolvers NXDOMAIN mining-pool hostnames while still resolving
  # their websites, and VPN gateways transparently redirect port 53, both of
  # which make `networking.nameservers` advisory rather than binding. Strict
  # mode has no plaintext fallback, so a blocked 853 means no DNS at all --
  # accepted because that failure is loud, whereas the one it replaces is not.
  services.resolved = {
    enable = true;
    dnsovertls = "true";
    dnssec = "false";
    fallbackDns = [ "9.9.9.10#dns.quad9.net" "1.1.1.1#cloudflare-dns.com" ];
  };
  networking.nameservers = [ "9.9.9.10#dns.quad9.net" "1.1.1.1#cloudflare-dns.com" ];
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  time.timeZone = "Europe/Paris";
  i18n.defaultLocale = "en_GB.UTF-8";
  console.keyMap = "fr";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Without this, `nixos-rebuild --target-host admin@...` fails at the copy with
  # "cannot add path ... because it lacks a signature by a trusted key": an
  # unprivileged SSH user may only receive store paths signed by a key the
  # daemon trusts, and a locally-built system closure is signed by nothing.
  #
  # The workaround is to build on the target instead (--build-host), which is
  # what the rest of the fleet does. Declaring it here means a deploy from a
  # workstation works either way, which matters on this host: it is the one
  # machine in the fleet whose closure is expensive to build (latest kernel,
  # full firmware, Docker) and whose builder is by far the fastest.
  #
  # @wheel rather than a named user, so this does not have to change if the
  # admin account is ever renamed. Note that trusted users can influence what
  # the daemon builds and substitutes -- it is a privileged grant, and it is
  # already implied here by `admin` being in wheel with passwordless sudo.
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # ---------------------------------------------------------------------------
  # No desktop
  # ---------------------------------------------------------------------------
  # Wolf does not need one, and that is the whole point of running it rather
  # than Sunshine: each streaming session is a container carrying its own
  # compositor and userspace, so the host never logs anyone in, never starts a
  # display manager, and has no seat for a session to conflict over.
  services.xserver.enable = false;
  hardware.bluetooth.enable = false;

  # Audio is likewise per-session -- Wolf starts a PulseAudio container for
  # each one -- so the host runs no sound server of its own.
  services.pipewire.enable = false;

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------
  # One Linux account, three streaming users.
  #
  # The people who stream are Wolf clients, not Unix users, and that is a
  # deliberate choice rather than a shortcut. A Wolf session already runs as
  # its own container with its own /home, its own Steam login and its own
  # profile-data directory on the data disk, keyed by the client certificate
  # that Moonlight pairing hands out. Adding three shell accounts on the host
  # would give them no additional isolation, nothing to log into (there is no
  # desktop), and one more set of credentials to manage.
  #
  # Pairing is a runtime step, not a declarative one -- see the README.
  users.users.admin = {
    isNormalUser = true;
    description = "Administrator";
    extraGroups = [ "wheel" "docker" ];

    # Console fallback, shipped by `nixos-anywhere --extra-files` at install
    # time (scripts/mk-secrets.sh writes it). Out-of-store because everything
    # in /nix/store is world-readable, so a hash committed here would be
    # published to every local user.
    hashedPasswordFile = "/etc/admin.passwd";

    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@laptop"
    ];
  };

  # Membership in `docker` is root-equivalent (the socket will start a
  # container that bind-mounts /), so this is recorded rather than left
  # implicit: `admin` is a full admin on this box by two independent routes.

  # Unprivileged account for Home Assistant, as in the parent flake.
  users.users.ha = {
    isNormalUser = true;
    description = "Home Assistant remote control";
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... you@laptop"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = false;

  # Both disks are erased at install and there is no fallback OS on this
  # machine, so an unreachable result is not recoverable without a trip to it.
  # Fail the build instead of discovering that afterwards.
  assertions = [{
    # The offline installer adds keys at install time through
    # services.openssh.authorizedKeysFiles instead (installer/target.nix).
    assertion = config.users.users.admin.openssh.authorizedKeys.keys != [ ]
      || config.services.openssh.authorizedKeysFiles != [ ];
    message = ''
      users.users.admin has no SSH keys: the installed machine would be
      unreachable (key-only sshd, PermitRootLogin=no, no desktop, and no
      second OS to boot into).
    '';
  }];

  environment.systemPackages = with pkgs; [
    htop
    btop
    tmux
    git
    pciutils
    lm_sensors
    # Reads /dev/dri/by-path to confirm which render node is which card --
    # the check the README's post-install step depends on.
    libva-utils
    vulkan-tools
    radeontop
  ];

  system.stateVersion = "25.11";
}
