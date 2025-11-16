{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };
  outputs =
    {
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, system, ... }:
        {
          formatter = pkgs.nixpkgs-fmt;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              k9s
              kubectl
              python3
              makejinja
              talhelper
              cilium-cli
              cloudflared
              cue
              age
              fluxcd
              sops
              go-task
              kubernetes-helm
              helmfile
              jq
              kustomize
              kubectl
              yq
              talosctl
              kubeconform
              (pkgs.wrapHelm pkgs.kubernetes-helm { plugins = [ pkgs.kubernetes-helmPlugins.helm-diff ]; })
              minijinja
              pv-migrate
            ];

            shellHook = ''
              python3 -m venv .venv
              source .venv/bin/activate
              export KUBECONFIG="$PWD/kubeconfig"
              export SOPS_AGE_KEY_FILE="$PWD/age.key"
              export TALOSCONFIG="$PWD/talos/clusterconfig/talosconfig"
            '';

          };
        };
    };
}
