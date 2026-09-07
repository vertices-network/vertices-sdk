{
  description = "Vertices SDK development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          baseFoundrySources = {
            aarch64-darwin = {
              url = "https://github.com/base/base-anvil/releases/download/v1.1.0/foundry_v1.1.0_darwin_arm64.tar.gz";
              hash = "sha256-XZa2DXGI3fi4kNujVM5k9NzB/k6qiYtphXucIBLgrns=";
            };
            x86_64-darwin = {
              url = "https://github.com/base/base-anvil/releases/download/v1.1.0/foundry_v1.1.0_darwin_amd64.tar.gz";
              hash = "sha256-tiqiuvauPqh5BCMy8XolUVu+Yc5qVe9zcv49Pof7Roo=";
            };
            aarch64-linux = {
              url = "https://github.com/base/base-anvil/releases/download/v1.1.0/foundry_v1.1.0_linux_arm64.tar.gz";
              hash = "sha256-vOH6NQNRL70CT0qAfdFU9rat4c1hLz9oyVle/5MR0f8=";
            };
            x86_64-linux = {
              url = "https://github.com/base/base-anvil/releases/download/v1.1.0/foundry_v1.1.0_linux_amd64.tar.gz";
              hash = "sha256-uHznEr6Go6QXkajvztcfDLjXs6pzXOJ03HWnpjVQqfw=";
            };
          };
          baseFoundrySource = baseFoundrySources.${system}
            or (throw "Base Foundry is not packaged for ${system}");
          baseFoundry = pkgs.stdenvNoCC.mkDerivation {
            pname = "base-foundry";
            version = "1.1.0";
            src = pkgs.fetchurl baseFoundrySource;
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.makeWrapper ];
            installPhase = ''
              mkdir -p "$out/bin" "$out/libexec/base-foundry"
              tar -xzf "$src" -C "$out/libexec/base-foundry"
              for tool in forge cast anvil chisel; do
                chmod +x "$out/libexec/base-foundry/$tool"
              done
              makeWrapper "$out/libexec/base-foundry/forge" "$out/bin/base-forge" --set FOUNDRY_BASE true
              makeWrapper "$out/libexec/base-foundry/cast" "$out/bin/base-cast" --set FOUNDRY_BASE true
              makeWrapper "$out/libexec/base-foundry/anvil" "$out/bin/base-anvil" --add-flags --base
              makeWrapper "$out/libexec/base-foundry/chisel" "$out/bin/base-chisel" --set FOUNDRY_BASE true
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              rustfmt
              clippy
              rust-analyzer
              baseFoundry
              solc
              just
              pre-commit
              jq
              git
              nodejs_22
            ];

            shellHook = ''
              export RUST_BACKTRACE=1
              echo "Vertices environment ready: Rust $(rustc --version), Base Foundry $(base-forge --version | head -n1)"
            '';
          };
        });
    };
}
