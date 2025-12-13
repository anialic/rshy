<h1 align="center">flakey</h1>
<p align="center">An All-in-One NixOS Framework with Flakes</p>

> flakey is a minimal framework for managing NixOS/Darwin/Home Manager configurations. For general-purpose flake composition, consider flake-parts.

## Quick Start

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flakey.url = "github:anialic/flakey";
  
  outputs = { nixpkgs, flakey, ... }: flakey.mkFlake { inherit nixpkgs; src = ./.; };
}
```

```nix
# modules/base.nix
{ lib, ... }:
{
  modules.base = {
    target = "nixos";
    options.hostName = lib.mkOption { type = lib.types.str; };
    module = { node, ... }: {
      networking.hostName = node.base.hostName;
      boot.loader.grub.device = "nodev";
      fileSystems."/".device = "/dev/sda1";
      system.stateVersion = "25.11";
    };
  };
}
```

```nix
# nodes.nix
{
  nodes.my-machine = {
    system = "x86_64-linux";
    base.enable = true;
    base.hostName = "my-machine";
    extraModules = [ ];
  };
}
```

```bash
sudo nixos-rebuild switch --flake .#my-machine
```

## mkFlake

```nix
flakey.mkFlake {
  nixpkgs = ...;   # required
  src = ./.;       # required, scanned recursively for .nix files
  args = { };      # passed to all framework modules via specialArgs
  exclude = { name, path, relPath }: ...;  # file filter
}
```

Default exclude skips `_*`, `.*`, and `flake.nix`:

```nix
exclude = { name, ... }:
  let c = builtins.substring 0 1 name;
  in c == "_" || c == "." || name == "flake.nix";
```

## Module arguments:

| Arg | Description |
|-----|-------------|
| `node` | Current node config |
| `nodes` | All node configs |
| `name` | Node name |
| `system` | System string |
| `pkgs` | nixpkgs for this system |
| `pkgsFor` | nixpkgs abstraction: `pkgs = pkgsFor "aarch64-linux` |
| `...` | Everything from `args` |

## Module

```nix
modules.<name> = {
  target = "nixos";           # "nixos", "darwin", "home", or null (all targets)
  requires = [ "base" ];      # module dependencies, checked at build time
  options = { ... };          # option declarations
  module = { ... }: { ... };  # NixOS/Darwin/HM module
};
```

Options are automatically namespaced under the module name. Each module gets an implicit `enable` option.

Modules can be split across files and merged:

```nix
# modules/base.nix
{ lib, ... }:
{
  modules.base = {
    target = "nixos";
    options.hostName = lib.mkOption { type = lib.types.str; };
    module = { node, ... }: { networking.hostName = node.base.hostName; };
  };
}
```

```nix
# modules/base-ssh.nix
{ lib, ... }:
{
  modules.base = {
    options.enableSSH = lib.mkEnableOption "SSH";
    module = { node, ... }: { services.openssh.enable = node.base.enableSSH; };
  };
}
```

## Node

```nix
nodes.<name> = {
  system = "x86_64-linux";    # required
  target = "nixos";           # optional, inferred from system suffix
  <module>.enable = true;     # enable modules
  <module>.<option> = ...;    # set module options
  extraModules = [ ];         # additional NixOS/Darwin/HM modules
  instantiate = { system, modules, specialArgs }: ...;  # custom builder
};
```

Target inference: `*-darwin` → `darwin`, otherwise `nixos`.

Setting options without `enable = true` is an error. Unknown module names are rejected.

## Target

Framework only provides `nixos`. Define others as needed:

```nix
# targets.nix
{ nix-darwin, home-manager, nixpkgs, ... }:
{
  targets.darwin = {
    instantiate = { system, modules, specialArgs }:
      nix-darwin.lib.darwinSystem { inherit system modules specialArgs; };
    output = "darwinConfigurations";
  };

  targets.home = {
    instantiate = { system, modules, specialArgs }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit modules;
        extraSpecialArgs = specialArgs;
      };
    output = "homeConfigurations";
  };
}
```

## Rules

Assertions evaluated before building any configuration:

```nix
# rules.nix
{ config, ... }:
{
  rules = [
    {
      assertion = config.nodes != { };
      message = "at least one node required";
    }
    {
      assertion = builtins.all (n: n.base.enable or false) (builtins.attrValues config.nodes);
      message = "all nodes must enable base module";
    }
  ];
}
```

## perSystem & flake

```nix
# perSystem.nix
{
  perSystem = { pkgs, system }: {
    packages.hello = pkgs.hello;
    devShells.default = pkgs.mkShell { buildInputs = [ pkgs.git ]; };
    formatter = pkgs.alejandra;  # default: nixfmt-rfc-style
    apps.custom = { type = "app"; program = "${pkgs.hello}/bin/hello"; };
  };
}
```

```nix
# flake-extra.nix
{
  flake.overlays.default = final: prev: { };
  flake.lib.something = x: x;
}
```

## Built-in Apps

```bash
nix run .#allOptions    # list all modules and their options
nix run .#allNodes      # list all nodes and enabled modules
nix run .#checkOptions  # verify all options have defaults (exit 1 if not)
```

Output examples:

```
# nix run .#allOptions
## base [nixos]
  hostName: string
  enableSSH: boolean = false

## desktop [nixos] (requires: base)
  niri.enable: boolean = false
  niri.username: string
```

```
# nix run .#allNodes
## alice [nixos] (aarch64-linux)
  - base
  - desktop

## macbook [darwin] (aarch64-darwin)
  - darwinBase
```

## Examples

### Darwin

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    flakey.url = "github:anialic/flakey";
  };
  outputs = { nixpkgs, nix-darwin, flakey, ... }: flakey.mkFlake {
    inherit nixpkgs;
    src = ./.;
    args = { inherit nix-darwin; };
  };
}
```

```nix
# targets.nix
{ nix-darwin, ... }:
{
  targets.darwin = {
    instantiate = { system, modules, specialArgs }:
      nix-darwin.lib.darwinSystem { inherit system modules specialArgs; };
    output = "darwinConfigurations";
  };
}
```

```nix
# nodes.nix
{
  nodes.macbook = {
    system = "aarch64-darwin";
    darwinBase.enable = true;
    darwinBase.hostName = "macbook";
  };
}
```

### Home Manager

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    flakey.url = "github:anialic/flakey";
  };
  outputs = { nixpkgs, home-manager, flakey, ... }: flakey.mkFlake {
    inherit nixpkgs;
    src = ./.;
    args = { inherit nixpkgs home-manager; };
  };
}
```

```nix
# targets.nix
{ nixpkgs, home-manager, ... }:
{
  targets.home = {
    instantiate = { system, modules, specialArgs }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit modules;
        extraSpecialArgs = specialArgs;
      };
    output = "homeConfigurations";
  };
}
```

```nix
# nodes.nix
{
  nodes.alice = {
    system = "x86_64-linux";
    target = "home";
    hm.enable = true;
    hm.name = "alice";
  };
}
```

### Deploy-rs

```nix
# modules/deploy.nix
{ lib, ... }:
{
  modules.deploy = {
    options = {
      hostname = lib.mkOption { type = lib.types.str; };
      sshUser = lib.mkOption { type = lib.types.str; default = "root"; };
    };
  };
}
```

```nix
# deploy.nix
{ lib, config, deploy-rs, ... }:
let
  deployNodes = lib.filterAttrs (_: n: n.deploy.enable or false) config.nodes;
  getTarget = node: node._target or (if lib.hasSuffix "-darwin" node.system then "darwin" else "nixos");
in {
  flake.deploy.nodes = lib.mapAttrs (name: node:
    let
      target = getTarget node;
      cfg = config.flake.${config.targets.${target}.output}.${name};
    in {
      hostname = node.deploy.hostname;
      sshUser = node.deploy.sshUser;
      profiles.system = {
        user = "root";
        path = deploy-rs.lib.${node.system}.activate.${target} cfg;
      };
    }
  ) deployNodes;
}
```

```bash
nix run github:serokell/deploy-rs -- .#server
```

### Custom nixpkgs

```nix
# nodes.nix
{ nixpkgs-stable, ... }:
{
  nodes.stable-server = {
    system = "x86_64-linux";
    base.enable = true;
    base.hostName = "stable";
    instantiate = { system, modules, specialArgs }:
      nixpkgs-stable.lib.nixosSystem { inherit system modules specialArgs; };
  };
}
```

### Custom Formatter

```nix
# formatter.nix
{ nixpkgs, ... }:
{
  perSystem = { pkgs, ... }: {
    formatter = pkgs.writeShellApplication {
      name = "fmt";
      runtimeInputs = with pkgs; [ fd nixfmt-rfc-style deadnix statix ];
      text = ''
        fd -e nix -x nixfmt '{}'
        fd -e nix -x deadnix -e '{}'
        fd -e nix -x statix fix '{}'
      '';
    };
  };
}
```
