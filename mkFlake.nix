{
  nixpkgs,
  src,
  args ? { },
  exclude ? { name, ... }: let c = builtins.substring 0 1 name; in c == "_" || c == "." || name == "flake.nix",
}:
let
  inherit (nixpkgs) lib;

  scan = dir:
    lib.concatLists (
      lib.mapAttrsToList (name: type:
        let
          path = dir + "/${name}";
          relPath = lib.removePrefix (toString src + "/") (toString path);
        in
        if exclude { inherit name path relPath; } then [ ]
        else if type == "directory" then scan path
        else if type == "regular" && lib.hasSuffix ".nix" name then [ path ]
        else [ ]
      ) (builtins.readDir dir)
    );

  deepMerge = lib.mkOptionType {
    name = "deepMerge";
    check = builtins.isAttrs;
    merge = _: defs: lib.foldl' lib.recursiveUpdate { } (builtins.map (d: d.value) defs);
  };

  deferredModules = lib.mkOptionType {
    name = "deferredModules";
    check = x: builtins.isList x || builtins.isFunction x || builtins.isAttrs x;
    merge = _: defs: lib.concatMap (d: lib.toList d.value) defs;
  };

  coreModule = { config, ... }:
    let
      moduleEntries =
        lib.mapAttrsToList (name: spec:
          assert !(spec.options ? enable) || throw "flakey: module '${name}' cannot define 'enable'";
          { inherit name; inherit (spec) target requires options module; }
        ) config.modules;

      mkConditionalType = modName: modOptions:
        let
          enableOnly = lib.types.submodule { options.enable = lib.mkEnableOption modName; };
          fullType = lib.types.submodule { options = { enable = lib.mkEnableOption modName; } // modOptions; };
        in
        lib.mkOptionType {
          name = "conditionalModule(${modName})";
          check = builtins.isAttrs;
          merge = loc: defs:
            let
              merged = lib.foldl' lib.recursiveUpdate { } (builtins.map (d: d.value) defs);
              enabled = merged.enable or false;
              extraKeys = builtins.filter (k: k != "enable") (builtins.attrNames merged);
            in
            if !enabled && extraKeys != [ ] then
              throw "flakey: ${lib.concatStringsSep "." loc}: options set but enable = false (keys: ${lib.concatStringsSep ", " extraKeys})"
            else if enabled then
              fullType.merge loc defs
            else
              enableOnly.merge loc defs;
          getSubOptions = fullType.getSubOptions;
          getSubModules = fullType.getSubModules;
          substSubModules = _: mkConditionalType modName modOptions;
        };

      nodeOptions = lib.listToAttrs (builtins.map (m:
        lib.nameValuePair m.name (lib.mkOption {
          type = mkConditionalType m.name m.options;
          default = { };
        })
      ) moduleEntries);

      nodeType = lib.types.submodule {
        options = {
          system = lib.mkOption { type = lib.types.str; };
          target = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          extraModules = lib.mkOption { type = lib.types.listOf lib.types.deferredModule; default = [ ]; };
          instantiate = lib.mkOption { type = lib.types.nullOr lib.types.raw; default = null; };
        } // nodeOptions;
      };

      inferTarget = system: if lib.hasSuffix "-darwin" system then "darwin" else "nixos";

      enrichNode = name: node:
        let target = if node.target != null then node.target else inferTarget node.system;
        in {
          inherit name target;
          inherit (node) system;
          raw = node;
          clean = removeAttrs node [ "system" "target" "extraModules" "instantiate" ]
            // { _name = name; _system = node.system; _target = target; };
        };

      enrichedNodes = lib.mapAttrs enrichNode config.nodes;
      allNodes = lib.mapAttrs (_: n: n.clean) enrichedNodes;

      buildNode = name:
        let
          enriched = enrichedNodes.${name};
          checked = builtins.map (m:
            let
              enabled = enriched.raw.${m.name}.enable or false;
              targetMatch = m.target == null || m.target == enriched.target;
              missingDeps = lib.filter (dep: !(enriched.raw.${dep}.enable or false)) m.requires;
            in
            {
              inherit m enabled targetMatch missingDeps;
              error =
                if enabled && !targetMatch then
                  "${m.name}: requires target '${m.target}', got '${enriched.target}'"
                else if enabled && missingDeps != [ ] then
                  "${m.name}: requires ${lib.concatStringsSep ", " missingDeps}"
                else null;
            }
          ) moduleEntries;
          errors = builtins.filter (e: e != null) (builtins.map (c: c.error) checked);
          activeModules = builtins.filter (c: c.enabled && c.targetMatch && c.m.module != [ ]) checked;
          instantiate = if enriched.raw.instantiate != null then enriched.raw.instantiate
            else config.targets.${enriched.target}.instantiate
              or (throw "flakey: node '${name}' has undefined target '${enriched.target}'");
        in
        if errors != [ ] then
          throw ("flakey: configuration errors in node '${name}':\n" + lib.concatMapStringsSep "\n" (e: "  • ${e}") errors)
        else
          instantiate {
            system = enriched.system;
            specialArgs = { inherit name; system = enriched.system; node = enriched.clean; nodes = allNodes; } // args;
            modules = lib.concatMap (c: lib.toList c.m.module) activeModules ++ enriched.raw.extraModules;
          };

      nodesByTarget = builtins.groupBy (n: enrichedNodes.${n}.target) (builtins.attrNames enrichedNodes);

      targetOutputs = lib.mapAttrs' (target: def:
        lib.nameValuePair def.output (lib.genAttrs (nodesByTarget.${target} or [ ]) buildNode)
      ) config.targets;

      perSystemFor = system: config.perSystem { inherit system; pkgs = nixpkgs.legacyPackages.${system}; };

      mkPerSystemOutput = output:
        lib.filterAttrs (_: v: v != { })
          (lib.genAttrs config.systems (system: (perSystemFor system).${output} or { }));

      formatter = lib.genAttrs config.systems (system:
        (perSystemFor system).formatter or nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      optionsDoc =
        let
          collectPaths = prefix: opts:
            lib.concatLists (lib.mapAttrsToList (name: opt:
              let path = if prefix == "" then name else "${prefix}.${name}";
              in if opt ? _type && opt._type == "option" then
                [ { inherit path; type = opt.type.description or opt.type.name or "?"; default = opt.default or null; } ]
              else if builtins.isAttrs opt then collectPaths path opt
              else [ ]
            ) opts);
          formatModule = m:
            let
              paths = collectPaths "" m.options;
              targetStr = lib.optionalString (m.target != null) " [${m.target}]";
              requiresStr = lib.optionalString (m.requires != [ ]) " (requires: ${lib.concatStringsSep ", " m.requires})";
              optsStr = if paths == [ ] then "  (no options)"
                else lib.concatMapStringsSep "\n" (p:
                  "  ${p.path}: ${p.type}${lib.optionalString (p.default != null) " = ${builtins.toJSON p.default}"}"
                ) paths;
            in "## ${m.name}${targetStr}${requiresStr}\n${optsStr}";
        in
        lib.concatMapStringsSep "\n\n" formatModule moduleEntries;

      optionsCheck =
        let
          collectMissing = prefix: opts:
            lib.concatLists (lib.mapAttrsToList (name: opt:
              let path = if prefix == "" then name else "${prefix}.${name}";
              in if opt ? _type && opt._type == "option" then
                lib.optional (!(opt ? default)) path
              else if builtins.isAttrs opt then collectMissing path opt
              else [ ]
            ) opts);
          modulesWithMissing = lib.filter (m: m.missing != [ ]) (builtins.map (m: {
            inherit (m) name target;
            missing = collectMissing "" m.options;
          }) moduleEntries);
        in
        if modulesWithMissing == [ ] then
          "✓ All options have default values"
        else
          lib.concatMapStringsSep "\n\n" (m:
            "✗ ${m.name}${lib.optionalString (m.target != null) " [${m.target}]"}:\n${
              lib.concatMapStringsSep "\n" (p: "  - ${p}") m.missing
            }"
          ) modulesWithMissing;

      rulesErrors =
        let
          failed = builtins.filter (r: !r.assertion) config.rules;
        in
        builtins.map (r: r.message) failed;

      allOptionsApp = lib.genAttrs config.systems (system: {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${system}.writeShellScript "flakey-options" ''
          cat <<'EOF'
          # flakey modules

          ${optionsDoc}
          EOF
        '');
      });

      checkOptionsApp = lib.genAttrs config.systems (system: {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${system}.writeShellScript "flakey-check" ''
          cat <<'EOF'
          ${optionsCheck}
          EOF
          ${lib.optionalString (lib.hasPrefix "✗" optionsCheck) "exit 1"}
        '');
      });

      nodesDoc =
        let
          formatNode = name:
            let
              e = enrichedNodes.${name};
              enabledMods = lib.filter (m: e.raw.${m.name}.enable or false) moduleEntries;
              modsStr = if enabledMods == [ ] then "  (no modules)"
                else lib.concatMapStringsSep "\n" (m: "  - ${m.name}") enabledMods;
            in
            "## ${name} [${e.target}] (${e.system})\n${modsStr}";
        in
        lib.concatMapStringsSep "\n\n" formatNode (builtins.attrNames enrichedNodes);

      allNodesApp = lib.genAttrs config.systems (system: {
        type = "app";
        program = toString (nixpkgs.legacyPackages.${system}.writeShellScript "flakey-nodes" ''
          cat <<'EOF'
          # flakey nodes

          ${nodesDoc}
          EOF
        '');
      });

      checkRules =
        if rulesErrors != [ ] then
          throw ("flakey: rules failed:\n" + lib.concatMapStringsSep "\n" (e: "  • ${e}") rulesErrors)
        else true;

      targetOutputsChecked = lib.mapAttrs (_: configs:
        lib.mapAttrs (_: cfg: assert checkRules; cfg) configs
      ) targetOutputs;
    in
    {
      options = {
        systems = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
        };

        modules = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              target = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
              requires = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
              options = lib.mkOption { type = deepMerge; default = { }; };
              module = lib.mkOption { type = deferredModules; default = [ ]; };
            };
          });
          default = { };
        };

        targets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              instantiate = lib.mkOption { type = lib.types.raw; };
              output = lib.mkOption { type = lib.types.str; };
            };
          });
          default = { };
        };

        nodes = lib.mkOption { type = lib.types.attrsOf nodeType; default = { }; };

        rules = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              assertion = lib.mkOption { type = lib.types.bool; };
              message = lib.mkOption { type = lib.types.str; };
            };
          });
          default = [ ];
        };

        perSystem = lib.mkOption {
          type = lib.types.functionTo (lib.types.lazyAttrsOf lib.types.raw);
          default = _: { };
        };

        flake = lib.mkOption {
          type = lib.types.submoduleWith { modules = [{ freeformType = lib.types.lazyAttrsOf lib.types.raw; }]; };
          default = { };
        };
      };

      config = {
        targets.nixos = {
          instantiate = { system, modules, specialArgs }: lib.nixosSystem { inherit system modules specialArgs; };
          output = "nixosConfigurations";
        };

        flake =
          lib.mapAttrs (_: lib.mkDefault) targetOutputsChecked
          // { formatter = lib.mkDefault formatter; }
          // { apps = lib.mkDefault (lib.genAttrs config.systems (sys:
               (perSystemFor sys).apps or {} // {
                 allOptions = allOptionsApp.${sys};
                 allNodes = allNodesApp.${sys};
                 checkOptions = checkOptionsApp.${sys};
               })); }
          // lib.genAttrs [ "packages" "devShells" "checks" "legacyPackages" ]
            (o: lib.mkDefault (mkPerSystemOutput o));
      };
    };

  evaluated = lib.evalModules {
    modules = builtins.map import (scan src) ++ [ coreModule ];
    specialArgs = { inherit lib nixpkgs; pkgsFor = system: nixpkgs.legacyPackages.${system}; } // args;
  };
in
lib.filterAttrs (_: v: v != { }) evaluated.config.flake
