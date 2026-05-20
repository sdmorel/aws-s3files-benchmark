{
  description = "AWS S3 Benchmark development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = {self, nixpkgs}: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          awscli2
          opentofu
        ];

        shellHook = ''
          echo "AWS S3 Benchmark Development Environment"
          echo "=========================================="
          echo "Available tools:"
          echo "  - aws        (AWS CLI v2)"
          echo "  - tofu       (OpenTofu)"
          echo ""
          echo "Quick start:"
          echo "  1. cp terraform.tfvars.example terraform.tfvars"
          echo "  2. Edit terraform.tfvars with your values"
          echo "  3. tofu init && tofu apply"
          echo ""
        '';
      };
    });
  };
}