{
  description = "flakey";
  outputs = _: {
    mkFlake = import ./mkFlake.nix;
  };
}
