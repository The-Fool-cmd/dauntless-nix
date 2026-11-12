# Legendary 0.21.1, pinned. nixpkgs ships 0.20.34; docs/INSTALLING_DAUNTLESS.md needs >= 0.21.1.
{ python3Packages, fetchFromGitHub }:
python3Packages.buildPythonApplication {
  pname = "legendary-gl";
  version = "0.21.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "legendary-gl";
    repo = "legendary";
    rev = "42f6bdeadde3a9526dc8eb713763476999ac217b"; # tag 0.21.1
    hash = "sha256-BGLwnkYkaaIV9d4xauor4G/vDMTjyrR0c1f/LKPy0sg=";
  };

  # Upstream pins uv_build to >=0.11.4,<0.12; the nixpkgs build backend is older but compatible.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'requires = ["uv_build>=0.11.4,<0.12"]' 'requires = ["uv_build"]'
  '';

  build-system = [ python3Packages.uv-build ];
  dependencies = with python3Packages; [ requests filelock pycryptodomex ];

  pythonImportsCheck = [ "legendary" ];
  meta.mainProgram = "legendary";
}
