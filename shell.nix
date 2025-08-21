{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = with pkgs; [
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
}
