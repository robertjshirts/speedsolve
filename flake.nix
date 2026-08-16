{
  description = "Speedsolve backend development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = package: builtins.elem (nixpkgs.lib.getName package) [ "terraform" ];
          };

          python = pkgs.python313;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              python
              uv

              # Local database tools and service clients.
              postgresql_17
              redis

              # Infrastructure and deployment tools.
              terraform
              kubectl
              kubernetes-helm

              # Native build dependencies commonly needed by Python packages.
              pkg-config
              openssl
            ];

            env = {
              UV_PYTHON = "${python}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
            };

            shellHook = ''
              echo "Speedsolve development shell"
              echo "Python: $(python --version)"
              echo "Run 'uv sync' after pyproject.toml has been created."
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
